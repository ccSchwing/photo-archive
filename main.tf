# photo-archive — main.tf (single-file version)
#
# One terraform apply provisions AND configures everything:
#   VPC + subnet + internet gateway
#   t3.micro with Amazon Linux 2023
#   8 GiB root + 8 GiB data EBS volume (mounted at /srv/data)
#   Private S3 bucket
#   IAM role so the instance reaches S3 with no stored keys
#   nginx (public port 80) -> Flask on loopback -> presigned uploads to S3
#
# The whole web stack ships via user_data (first boot only):
#   nginx conf, Flask app, upload page, systemd service, Python venv
#
# Usage:
#   terraform init
#   terraform apply -var="key_name=photo-archive" -var="admin_cidr=YOUR.IP/32"
#   terraform destroy   # when idle — keeps the free tier free
#
# Note: user_data runs only on FIRST boot, and any change to it forces
# Terraform to replace the instance. That's fine here: photos live in S3,
# destroy/reapply is the intended workflow.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Exercise for later: S3 remote backend
  # backend "s3" {
  #   bucket = "your-terraform-state-bucket"
  #   key    = "photo-archive/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = var.region
}

# Latest Amazon Linux 2023, x86_64 (keep x86 for t3.micro free-tier eligibility)
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type (t3.micro = free tier)"
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "Existing EC2 key pair name for SSH access"
  type        = string
}

variable "admin_cidr" {
  description = "Your IP in CIDR form, e.g. 203.0.113.4/32"
  type        = string
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB"
  type        = number
  default     = 8
}

variable "data_volume_size" {
  description = "Extra data EBS volume size in GiB"
  type        = number
  default     = 8
}

# ---------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "photo-archive-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true

  tags = { Name = "photo-archive-public-a" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "photo-archive-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "photo-archive-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------
# S3 bucket
# ---------------------------------------------------------------------

resource "aws_s3_bucket" "photos" {
  bucket        = "photo-archive-${data.aws_caller_identity.current.account_id}"
  force_destroy = false # deliberate friction before deleting your photos
}

resource "aws_s3_bucket_public_access_block" "photos" {
  bucket                  = aws_s3_bucket.photos.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "photos" {
  bucket = aws_s3_bucket.photos.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------------------------------------------------------------------
# IAM — instance talks to S3 via role, never stored keys
# ---------------------------------------------------------------------

resource "aws_iam_role" "app" {
  name = "photo-archive-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "s3_photos" {
  name = "s3-photos-access"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:DeleteObject"]
      Resource = [
        aws_s3_bucket.photos.arn,
        "${aws_s3_bucket.photos.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "photo-archive-app-profile"
  role = aws_iam_role.app.name
}

# ---------------------------------------------------------------------
# EC2: security group, instance, data volume
# ---------------------------------------------------------------------

resource "aws_security_group" "web" {
  name        = "photo-archive-web-sg"
  description = "SSH for admin, HTTP for the app"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from admin only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "photo-archive-web-sg" }
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web.id]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.app.name

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
  }

  # Everything below runs once, on first boot, as root.
  # Heredocs with QUOTED delimiters ('PY', 'NGINX') are passed through
  # verbatim; the SERVICE one is unquoted so the bucket name interpolates.
  user_data = <<-USERDATA
    #!/bin/bash
    set -euxo pipefail

    dnf update -y
    dnf install -y nginx python3-pip

    mkdir -p /opt/photo-archive/static

    # --- nginx: public face, proxies everything to Flask on loopback ---
    cat > /etc/nginx/conf.d/photo-archive.conf <<'NGINX_CONF'
    server {
        listen 80;
        server_name _;

        location / {
            proxy_pass         http://127.0.0.1:8000;
            proxy_set_header   Host              $host;
            proxy_set_header   X-Real-IP         $remote_addr;
            proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
        }
    }
    NGINX_CONF

    # --- Flask app: mints presigned POST uploads using the IAM role ---
    cat > /opt/photo-archive/app.py <<'PY'
    import os
    from datetime import datetime, timezone

    import boto3
    from flask import Flask, jsonify, request, send_from_directory

    app = Flask(__name__, static_folder="static")

    BUCKET = os.environ["PHOTO_BUCKET"]
    PREFIX = "uploads"

    s3 = boto3.client("s3")  # credentials come from the instance role


    @app.route("/")
    def index():
        return send_from_directory(app.static_folder, "index.html")


    @app.route("/presign", methods=["POST"])
    def presign():
        """Mint a presigned POST so the browser uploads straight to S3."""
        body = request.get_json(force=True)
        filename = os.path.basename(body.get("filename", "unnamed"))
        content_type = body.get("content_type", "application/octet-stream")

        today = datetime.now(timezone.utc)
        key = PREFIX + "/" + today.strftime("%Y/%m/%d") + "/" + filename

        return jsonify(s3.generate_presigned_post(
            Bucket=BUCKET,
            Key=key,
            Fields={"Content-Type": content_type},
            Conditions=[
                {"Content-Type": content_type},
                ["content-length-range", 1, 104857600],  # 1 byte .. 100 MiB
            ],
            ExpiresIn=3600,
        ))


    @app.route("/health")
    def health():
        return {"ok": True}


    if __name__ == "__main__":
        app.run(host="127.0.0.1", port=8000)
    PY

    # --- Upload page: browser -> nginx -> Flask for presign, -> S3 for bytes ---
    cat > /opt/photo-archive/static/index.html <<'HTML'
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <title>Photo Archive</title>
    <style>
      body { font-family: system-ui, sans-serif; max-width: 40rem; margin: 3rem auto; }
      #status { margin-top: 1rem; color: #555; }
    </style>
    </head>
    <body>
    <h1>Photo Archive</h1>
    <input type="file" id="file" multiple accept="image/*,video/*">
    <div id="status"></div>

    <script>
    var statusEl = document.getElementById("status");

    function say(msg) { statusEl.textContent = msg; }

    async function upload(file) {
      var res = await fetch("/presign", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          filename: file.name,
          content_type: file.type || "application/octet-stream"
        })
      });
      if (!res.ok) throw new Error("presign failed (" + res.status + ")");
      var presigned = await res.json();

      var form = new FormData();
      Object.keys(presigned.fields).forEach(function (k) {
        form.append(k, presigned.fields[k]);
      });
      form.append("file", file);

      var up = await fetch(presigned.url, { method: "POST", body: form });
      if (!up.ok) throw new Error("upload failed (" + up.status + ")");
      return presigned.fields.key;
    }

    document.getElementById("file").addEventListener("change", async function (e) {
      var files = Array.from(e.target.files);
      for (var i = 0; i < files.length; i++) {
        say("Uploading " + files[i].name + " ...");
        try {
          var key = await upload(files[i]);
          say("Done: " + key);
        } catch (err) {
          say("Failed: " + err.message);
        }
      }
    });
    </script>
    </body>
    </html>
    HTML

    # --- systemd unit (unquoted heredoc: Terraform inserts the bucket name) ---
    cat > /etc/systemd/system/photo-archive.service <<SERVICE
    [Unit]
    Description=Photo Archive presign service
    After=network-online.target
    Wants=network-online.target

    [Service]
    User=ec2-user
    WorkingDirectory=/opt/photo-archive
    Environment=PHOTO_BUCKET=${aws_s3_bucket.photos.bucket}
    ExecStart=/opt/photo-archive/venv/bin/python3 /opt/photo-archive/app.py
    Restart=on-failure
    RestartSec=3

    [Install]
    WantedBy=multi-user.target
    SERVICE

    # --- Python venv: sidesteps the "externally-managed environment" wall ---
    python3 -m venv /opt/photo-archive/venv
    /opt/photo-archive/venv/bin/pip install --upgrade pip
    /opt/photo-archive/venv/bin/pip install flask boto3
    chown -R ec2-user:ec2-user /opt/photo-archive

    # --- Start everything ---
    systemctl daemon-reload
    systemctl enable --now nginx
    systemctl enable --now photo-archive

    # --- Format and mount the data volume (waits for attachment) ---
    DEVICE=/dev/xvdf
    for i in $(seq 1 30); do [ -b $DEVICE ] && break; sleep 2; done
    if [ -b $DEVICE ] && ! blkid $DEVICE; then mkfs -t xfs $DEVICE; fi
    mkdir -p /srv/data
    mount $DEVICE /srv/data
    echo "$DEVICE /srv/data xfs defaults,nofail 0 2" >> /etc/fstab
  USERDATA

  tags = { Name = "photo-archive-app" }
}

resource "aws_ebs_volume" "data" {
  availability_zone = aws_instance.app.availability_zone
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true

  tags = { Name = "photo-archive-data" }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.app.id
}

# ---------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------

output "instance_public_ip" {
  value       = aws_instance.app.public_ip
  description = "Point your browser here; SSH with ec2-user@ + your key"
}

output "bucket_name" {
  value = aws_s3_bucket.photos.id
}

output "ssh_command" {
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_instance.app.public_ip}"
  description = "Ready-made SSH command"
}
