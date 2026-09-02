"""
Diagram-as-code: what happens when a developer pushes application code.

Usage:
    pip install diagrams
    # also install the Graphviz binary (`dot`) for your OS, e.g.:
    #   macOS:   brew install graphviz
    #   Ubuntu:  sudo apt-get install graphviz
    #   Windows: choco install graphviz
    python cicd_push_flow_diagram.py
    # -> writes cicd_push_flow.png next to this script
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import ECR, ElasticContainerServiceContainer
from diagrams.aws.devtools import Codedeploy, Codepipeline
from diagrams.aws.general import Users
from diagrams.aws.integration import Eventbridge
from diagrams.aws.management import Cloudwatch
from diagrams.aws.security import IdentityAndAccessManagementIamPermissions
from diagrams.onprem.ci import GithubActions
from diagrams.onprem.vcs import Github

graph_attr = {
    "fontsize": "14",
    "bgcolor": "white",
    "pad": "0.5",
    "splines": "ortho",
}

with Diagram(
    "Photo Gallery - Developer Push to Deploy",
    filename="cicd_push_flow",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
):
    developer = Users("Developer")

    with Cluster("GitHub: photo-uploader-app"):
        repo = Github("main branch")
        actions = GithubActions("GitHub Actions\n(test, build, docker push)")

    oidc_role = IdentityAndAccessManagementIamPermissions(
        "GitHub OIDC role\n(github-actions-ecr-push,\nno long-lived keys)"
    )

    ecr = ECR("ECR\napp image")

    with Cluster("AWS: CI/CD pipeline"):
        eventbridge = Eventbridge("EventBridge rule\n(image push,\ntag=latest)")
        pipeline = Codepipeline("CodePipeline")
        codedeploy = Codedeploy("CodeDeploy\n(ECS blue/green)")

    with Cluster("ECS Fargate service"):
        blue = ElasticContainerServiceContainer("Blue task set\n(current prod)")
        green = ElasticContainerServiceContainer("Green task set\n(new revision)")

    alarms = Cloudwatch("CloudWatch alarms\n(target group health)")

    developer >> Edge(label="1. git push") >> repo
    repo >> Edge(label="2. triggers on push") >> actions
    actions >> Edge(label="3. assume role\n(OIDC)") >> oidc_role
    oidc_role >> Edge(label="4. docker push\n:latest, :sha") >> ecr

    ecr >> Edge(label="5. ECR Image Action\n(PUSH, SUCCESS)") >> eventbridge
    eventbridge >> Edge(label="6. start execution") >> pipeline
    repo >> Edge(
        label="source: ecs/taskdef.json\n+ ecs/appspec.yaml",
        style="dashed",
    ) >> pipeline
    pipeline >> Edge(label="7. create deployment") >> codedeploy

    codedeploy >> Edge(label="8. install new\ntask definition") >> green
    codedeploy >> Edge(
        label="9. shift prod traffic\nto green, then\nterminate blue",
        style="bold",
    ) >> green
    green >> Edge(style="dotted") >> alarms
    blue >> Edge(style="dotted") >> alarms
    alarms >> Edge(
        label="10. auto-rollback\non alarm",
        style="dashed",
        color="firebrick",
    ) >> codedeploy
