from datetime import datetime, timezone
from services.catalog.models import db


class Inventory(db.Model):
    __tablename__ = "inventory"

    id = db.Column(db.Integer, primary_key=True)
    product_id = db.Column(db.Integer, nullable=False, index=True)
    quantity = db.Column(db.Integer, nullable=False, default=0)
    warehouse = db.Column(db.String(100), default="main")
    updated_at = db.Column(
        db.DateTime,
        default=lambda: datetime.now(timezone.utc),
        onupdate=lambda: datetime.now(timezone.utc),
    )

    def to_dict(self):
        return {
            "id": self.id,
            "product_id": self.product_id,
            "quantity": self.quantity,
            "warehouse": self.warehouse,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
        }
