import os
import uuid
import boto3
from flask import current_app


class LocalStorage:
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
        filepath = os.path.join(
            current_app.config["UPLOAD_FOLDER"], os.path.basename(image_path)
        )
        if os.path.exists(filepath):
            os.remove(filepath)


class S3Storage:
    def __init__(self, bucket):
        self.bucket = bucket
        self.s3 = boto3.client("s3")

    def save(self, file):
        ext = os.path.splitext(file.filename)[1] or ".jpg"
        key = f"uploads/{uuid.uuid4().hex}{ext}"
        self.s3.upload_fileobj(file, self.bucket, key, ExtraArgs={
            "ContentType": file.content_type or "application/octet-stream",
        })
        return key

    def get_url(self, image_path):
        if not image_path:
            return ""
        return f"https://{self.bucket}.s3.amazonaws.com/{image_path}"

    def delete(self, image_path):
        if not image_path:
            return
        self.s3.delete_object(Bucket=self.bucket, Key=image_path)


def _create_storage():
    use_object_storage = os.environ.get("USE_OBJECT_STORAGE")
    object_store_location = os.environ.get("OBJECT_STORE_LOCATION")
    if use_object_storage and object_store_location:
        return S3Storage(object_store_location)
    return LocalStorage()


storage = _create_storage()
