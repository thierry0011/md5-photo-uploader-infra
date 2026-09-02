"""
Diagram-as-code for the Photo Gallery architecture.

Usage:
    pip install diagrams
    # also install the Graphviz binary (`dot`) for your OS, e.g.:
    #   macOS:   brew install graphviz
    #   Ubuntu:  sudo apt-get install graphviz
    #   Windows: choco install graphviz
    python architecture_diagram.py
    # -> writes architecture.png next to this script
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import ECR, ElasticContainerServiceContainer
from diagrams.aws.database import RDS
from diagrams.aws.devtools import Codepipeline, Codedeploy
from diagrams.aws.general import Users
from diagrams.aws.integration import Eventbridge
from diagrams.aws.management import Cloudwatch
from diagrams.aws.network import (
    ALB,
    CloudFront,
    Endpoint,
    InternetGateway,
    PrivateSubnet,
    PublicSubnet,
    VPC,
)
from diagrams.aws.security import IdentityAndAccessManagementIamPermissions, KMS
from diagrams.aws.storage import S3
from diagrams.onprem.vcs import Github

graph_attr = {
    "fontsize": "14",
    "bgcolor": "white",
    "pad": "0.5",
    "splines": "ortho",
}

with Diagram(
    "Photo Gallery - AWS Architecture",
    filename="architecture",
    show=False,
    direction="TB",
    graph_attr=graph_attr,
):
    users = Users("End users\n(browser)")

    with Cluster("GitHub"):
        app_repo = Github("photo-uploader-app\n(Django, Dockerfile,\ntaskdef/appspec)")
        infra_repo = Github("photo-uploader-infra\n(CloudFormation)")

    oidc = IdentityAndAccessManagementIamPermissions("GitHub OIDC role\n(no long-lived keys)")

    cdn = CloudFront("CloudFront\nPrice Class 200")

    with Cluster("VPC (Multi-AZ)"):
        igw = InternetGateway("Internet Gateway")

        with Cluster("Public subnets (AZ-a / AZ-b)"):
            alb = ALB("Application\nLoad Balancer")

        with Cluster("Private subnets (AZ-a / AZ-b)"):
            with Cluster("ECS Fargate service (1-4 tasks)"):
                svc_blue = ElasticContainerServiceContainer("Blue task set")
                svc_green = ElasticContainerServiceContainer("Green task set")
            db = RDS("RDS PostgreSQL\n(db.t3, single-AZ -\nno standby replica)")

        with Cluster("VPC Endpoints (no NAT)"):
            vpce = Endpoint("ECR / S3 / Logs /\nSecrets Manager")

    images_bucket = S3("S3: images\n(private, KMS)")
    kms = KMS("KMS CMK")

    with Cluster("CI/CD"):
        ecr = ECR("ECR: app image")
        eventbridge = Eventbridge("EventBridge rule\n(ECR push)")
        pipeline = Codepipeline("CodePipeline")
        codedeploy = Codedeploy("CodeDeploy\n(blue/green)")

    cw = Cloudwatch("CloudWatch Logs\n/ecs/photo-gallery")

    users >> Edge(label="HTTPS") >> cdn >> Edge(label="OAC") >> images_bucket
    users >> Edge(label="HTTP") >> alb >> Edge(label=":8000") >> svc_blue
    alb >> Edge(style="dashed", label="test listener") >> svc_green

    igw >> alb

    svc_blue >> Edge(label="R/W") >> db
    svc_blue >> Edge(label="upload") >> images_bucket
    svc_blue >> cw
    db >> Edge(style="dotted") >> kms
    images_bucket >> Edge(style="dotted") >> kms

    app_repo >> Edge(label="OIDC assume-role") >> oidc >> Edge(label="docker push") >> ecr
    ecr >> eventbridge >> pipeline
    app_repo >> Edge(label="taskdef.json /\nappspec.yaml", style="dashed") >> pipeline
    pipeline >> codedeploy >> Edge(label="shift traffic") >> svc_green

    infra_repo >> Edge(label="Git sync", color="darkgreen") >> vpce
