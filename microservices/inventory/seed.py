"""Seed the inventory database with sample stock levels."""
from .app import create_app
from .models import db, Inventory

STOCK = [
    {"product_id": 1, "quantity": 50, "warehouse": "main"},
    {"product_id": 2, "quantity": 30, "warehouse": "main"},
    {"product_id": 3, "quantity": 100, "warehouse": "main"},
    {"product_id": 4, "quantity": 75, "warehouse": "main"},
    {"product_id": 5, "quantity": 45, "warehouse": "main"},
]

app = create_app()


def seed():
    with app.app_context():
        db.create_all()
        if Inventory.query.first():
            print("Inventory already has data. Skipping seed.")
            return

        for s in STOCK:
            db.session.add(Inventory(**s))

        db.session.commit()
        print(f"Seeded {len(STOCK)} inventory records.")


if __name__ == "__main__":
    seed()
