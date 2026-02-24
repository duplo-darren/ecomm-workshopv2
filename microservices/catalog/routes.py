from flask import request, jsonify, Blueprint
from .models import db, Product
from .storage import storage

catalog_bp = Blueprint("catalog", __name__)


@catalog_bp.route("/products", methods=["GET"])
def list_products():
    products = Product.query.order_by(Product.created_at.desc()).all()
    result = []
    for p in products:
        data = p.to_dict()
        data["image_url"] = storage.get_url(p.image_path)
        result.append(data)
    return jsonify(result)


@catalog_bp.route("/products/<int:product_id>", methods=["GET"])
def get_product(product_id):
    product = db.session.get(Product, product_id)
    if not product:
        return jsonify({"error": "Product not found"}), 404
    data = product.to_dict()
    data["image_url"] = storage.get_url(product.image_path)
    return jsonify(data)


@catalog_bp.route("/products", methods=["POST"])
def create_product():
    name = request.form.get("name")
    description = request.form.get("description", "")
    price = request.form.get("price", type=float)

    if not name or price is None:
        return jsonify({"error": "name and price are required"}), 400

    image_path = ""
    if "image" in request.files and request.files["image"].filename:
        image_path = storage.save(request.files["image"])

    product = Product(
        name=name, description=description, price=price, image_path=image_path
    )
    db.session.add(product)
    db.session.commit()

    return jsonify(product.to_dict()), 201


@catalog_bp.route("/products/<int:product_id>", methods=["PUT"])
def update_product(product_id):
    product = db.session.get(Product, product_id)
    if not product:
        return jsonify({"error": "Product not found"}), 404

    data = request.get_json()
    if "name" in data:
        product.name = data["name"]
    if "description" in data:
        product.description = data["description"]
    if "price" in data:
        product.price = data["price"]

    db.session.commit()
    return jsonify(product.to_dict())


@catalog_bp.route("/products/<int:product_id>", methods=["DELETE"])
def delete_product(product_id):
    product = db.session.get(Product, product_id)
    if not product:
        return jsonify({"error": "Product not found"}), 404

    if product.image_path:
        storage.delete(product.image_path)

    db.session.delete(product)
    db.session.commit()
    return jsonify({"message": "Product deleted"})
