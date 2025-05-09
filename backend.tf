terraform {
  backend "s3" {
    bucket         = "v-backend-s3"       # Replace with your actual bucket name
    key            = "us-east-1/terraform.tfstate"   # Path to the state file within the bucket
    region         = "us-east-1"
    encrypt        = true
  }
}

