from flask import request, jsonify
from . import inventory_bp
from .models import db, Inventory


@inventory_bp.route("/inventory", methods=["GET"])
def list_inventory():
    items = Inventory.query.all()
    return jsonify([i.to_dict() for i in items])


@inventory_bp.route("/inventory/<int:product_id>", methods=["GET"])
def get_inventory(product_id):
    item = Inventory.query.filter_by(product_id=product_id).first()
    if not item:
        return jsonify({"product_id": product_id, "quantity": 0, "warehouse": "main"})
    return jsonify(item.to_dict())


@inventory_bp.route("/inventory/<int:product_id>", methods=["PUT"])
def update_inventory(product_id):
    data = request.get_json()
    item = Inventory.query.filter_by(product_id=product_id).first()

    if not item:
        item = Inventory(
            product_id=product_id,
            quantity=data.get("quantity", 0),
            warehouse=data.get("warehouse", "main"),
        )
        db.session.add(item)
    else:
        if "quantity" in data:
            item.quantity = data["quantity"]
        if "warehouse" in data:
            item.warehouse = data["warehouse"]

    db.session.commit()
    return jsonify(item.to_dict())
