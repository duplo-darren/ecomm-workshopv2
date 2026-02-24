from flask import render_template, redirect, url_for, request, flash
from . import frontend_bp
from services import ServiceClient


@frontend_bp.route("/")
def index():
    products = ServiceClient.get("catalog", "/products")
    return render_template("index.html", products=products)


@frontend_bp.route("/products/<int:product_id>")
def product_detail(product_id):
    product = ServiceClient.get("catalog", f"/products/{product_id}")
    inventory = ServiceClient.get("inventory", f"/inventory/{product_id}")
    return render_template("product.html", product=product, inventory=inventory)


@frontend_bp.route("/admin")
def admin():
    products = ServiceClient.get("catalog", "/products")
    return render_template("admin.html", products=products)


@frontend_bp.route("/admin/add-product", methods=["POST"])
def add_product():
    from services.catalog.models import db, Product
    from services.catalog.storage import storage

    name = request.form.get("name")
    description = request.form.get("description", "")
    price = request.form.get("price", type=float)

    image_path = ""
    if "image" in request.files and request.files["image"].filename:
        image_path = storage.save(request.files["image"])

    product = Product(
        name=name, description=description, price=price, image_path=image_path
    )
    db.session.add(product)
    db.session.commit()

    return redirect("/admin")


@frontend_bp.route("/products/<int:product_id>/inventory", methods=["POST"])
def update_inventory(product_id):
    data = {
        "quantity": int(request.form.get("quantity", 0)),
        "warehouse": request.form.get("warehouse", "main"),
    }
    ServiceClient.put("inventory", f"/inventory/{product_id}", json=data)
    return redirect(f"/products/{product_id}")
