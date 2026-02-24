from flask import render_template, redirect, request, Blueprint
from .service_client import ServiceClient

frontend_bp = Blueprint(
    "frontend", __name__, template_folder="templates"
)


@frontend_bp.route("/")
def index():
    products = ServiceClient.get("catalog", "/api/products")
    return render_template("index.html", products=products)


@frontend_bp.route("/products/<int:product_id>")
def product_detail(product_id):
    product = ServiceClient.get("catalog", f"/api/products/{product_id}")
    inventory = ServiceClient.get("inventory", f"/api/inventory/{product_id}")
    return render_template("product.html", product=product, inventory=inventory)


@frontend_bp.route("/admin")
def admin():
    products = ServiceClient.get("catalog", "/api/products")
    return render_template("admin.html", products=products)


@frontend_bp.route("/admin/add-product", methods=["POST"])
def add_product():
    form_data = {
        "name": request.form.get("name"),
        "description": request.form.get("description", ""),
        "price": request.form.get("price"),
    }

    files = {}
    if "image" in request.files and request.files["image"].filename:
        image = request.files["image"]
        files["image"] = (image.filename, image.stream, image.content_type)

    ServiceClient.post("catalog", "/api/products", data=form_data, files=files)
    return redirect("/admin")


@frontend_bp.route("/products/<int:product_id>/inventory", methods=["POST"])
def update_inventory(product_id):
    data = {
        "quantity": int(request.form.get("quantity", 0)),
        "warehouse": request.form.get("warehouse", "main"),
    }
    ServiceClient.put("inventory", f"/api/inventory/{product_id}", json=data)
    return redirect(f"/products/{product_id}")
