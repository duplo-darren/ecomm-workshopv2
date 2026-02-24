import os
import uuid
from flask import current_app


class LocalStorage:
    """Local filesystem storage for product images.

    During the workshop, participants replace this with an S3Storage
    implementation that uses boto3.
    """

    def save(self, file):
        upload_folder = current_app.config["UPLOAD_FOLDER"]
        os.makedirs(upload_folder, exist_ok=True)
        ext = os.path.splitext(file.filename)[1] or ".jpg"
        filename = f"{uuid.uuid4().hex}{ext}"
        filepath = os.path.join(upload_folder, filename)
        file.save(filepath)
        return f"uploads/{filename}"

    def get_url(self, image_path):
        if not image_path:
            return ""
        return f"/static/{image_path}"

    def delete(self, image_path):
        if not image_path:
            return
        filepath = os.path.join(current_app.config["UPLOAD_FOLDER"],
                                os.path.basename(image_path))
        if os.path.exists(filepath):
            os.remove(filepath)


storage = LocalStorage()
