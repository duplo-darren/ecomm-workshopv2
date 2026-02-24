"""Seed the catalog database with sample products."""
import os
import shutil
import uuid
from .app import create_app
from .models import db, Product

SEED_IMAGES_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "seed_images")
UPLOAD_DIR = os.path.join(os.path.dirname(__file__), "static", "uploads")

PRODUCTS = [
    {"name": "Wireless Headphones", "description": "Noise-cancelling over-ear headphones with 30hr battery life.", "price": 79.99, "image": "headphones.jpg"},
    {"name": "Mechanical Keyboard", "description": "RGB mechanical keyboard with Cherry MX switches.", "price": 129.99, "image": "keyboard.jpg"},
    {"name": "USB-C Hub", "description": "7-in-1 USB-C hub with HDMI, USB 3.0, and SD card reader.", "price": 49.99, "image": "usb-hub.jpg"},
    {"name": "Laptop Stand", "description": "Adjustable aluminum laptop stand for ergonomic viewing.", "price": 34.99, "image": "laptop-stand.jpg"},
    {"name": "Webcam HD", "description": "1080p webcam with built-in microphone and auto-focus.", "price": 59.99, "image": "webcam.jpg"},
]

app = create_app()


def seed():
    with app.app_context():
        db.create_all()
        if Product.query.first():
            print("Catalog already has data. Skipping seed.")
            return

        os.makedirs(UPLOAD_DIR, exist_ok=True)
        for p in PRODUCTS:
            image_file = p.pop("image")
            src = os.path.join(SEED_IMAGES_DIR, image_file)
            if os.path.exists(src):
                ext = os.path.splitext(image_file)[1]
                dest_name = f"{uuid.uuid4().hex}{ext}"
                shutil.copy2(src, os.path.join(UPLOAD_DIR, dest_name))
                p["image_path"] = f"uploads/{dest_name}"

            product = Product(**p)
            db.session.add(product)

        db.session.commit()
        print(f"Seeded {len(PRODUCTS)} products.")


if __name__ == "__main__":
    seed()
