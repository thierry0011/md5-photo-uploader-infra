"""
Diagram-as-code: what happens when a visitor loads the gallery page and
uploads a photo. Traced from the actual Django view/form code
(photo-uploader-app/gallery/views.py, gallery/forms.py) - the app uploads
straight to S3 through Django/boto3 using the ECS task role; there is no
browser-to-S3 presigned URL in this design.

Usage:
    pip install diagrams
    # also install the Graphviz binary (`dot`) for your OS, e.g.:
    #   macOS:   brew install graphviz
    #   Ubuntu:  sudo apt-get install graphviz
    #   Windows: choco install graphviz
    python user_upload_flow_diagram.py
    # -> writes user_upload_flow.png next to this script
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import ElasticContainerServiceContainer
from diagrams.aws.database import RDS
from diagrams.aws.general import Users
from diagrams.aws.network import ALB, CloudFront
from diagrams.aws.security import KMS
from diagrams.aws.storage import S3

graph_attr = {
    "fontsize": "14",
    "bgcolor": "white",
    "pad": "0.5",
    "splines": "ortho",
}

VIEW_COLOR = "#1a73e8"
UPLOAD_COLOR = "#e8710a"

with Diagram(
    "Photo Gallery - Visitor Views & Uploads a Photo",
    filename="user_upload_flow",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
):
    visitor = Users("Visitor\n(browser)")
    cdn = CloudFront("CloudFront\n(image delivery, OAC)")
    alb = ALB("Application\nLoad Balancer")

    with Cluster("ECS Fargate task (private subnet)"):
        app = ElasticContainerServiceContainer("Django app\n(Gunicorn, :8000)")

    with Cluster("Private subnet"):
        db = RDS("RDS PostgreSQL\n(Photo: image key,\ndescription)")

    images_bucket = S3("S3: images\n(private, KMS,\nread only via CloudFront)")
    kms = KMS("KMS CMK")

    # ---------------- View flow (blue) ----------------
    visitor >> Edge(label="1. GET /", color=VIEW_COLOR) >> alb
    alb >> Edge(label="2. forward :8000", color=VIEW_COLOR) >> app
    app >> Edge(label="3. SELECT photos", color=VIEW_COLOR) >> db
    app >> Edge(
        label="4. render HTML\n(img src = CloudFront URL)",
        color=VIEW_COLOR,
    ) >> alb
    alb >> Edge(label="5. HTML response", color=VIEW_COLOR) >> visitor
    visitor >> Edge(
        label="6. GET each image\n(HTTPS, direct)",
        color=VIEW_COLOR,
    ) >> cdn
    cdn >> Edge(label="7. cache miss ->\nfetch via OAC", color=VIEW_COLOR) >> images_bucket
    cdn >> Edge(label="8. image bytes", color=VIEW_COLOR) >> visitor

    # ---------------- Upload flow (orange) ----------------
    visitor >> Edge(
        label="A. POST /upload\n(multipart: image + description)",
        color=UPLOAD_COLOR,
    ) >> alb
    alb >> Edge(label="B. forward :8000", color=UPLOAD_COLOR) >> app
    app >> Edge(
        label="C. validate (size <= 8MB,\nPillow check), then put_object\n(task role, SSE-KMS)",
        color=UPLOAD_COLOR,
    ) >> images_bucket
    app >> Edge(
        label="D. INSERT Photo\n(image key, description)",
        color=UPLOAD_COLOR,
    ) >> db
    app >> Edge(label="E. redirect ->\ngallery index", color=UPLOAD_COLOR) >> alb
    alb >> Edge(label="F. 302 + success", color=UPLOAD_COLOR) >> visitor

    images_bucket >> Edge(style="dotted") >> kms
    db >> Edge(style="dotted") >> kms
