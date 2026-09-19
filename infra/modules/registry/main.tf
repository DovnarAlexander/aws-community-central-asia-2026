# One repository for one image.
#
# The api and the worker are the same binary in the same image, selected by
# argv -- the same trick the original demo used for its failure modes, applied
# one level up. Two commands, one artifact to build and push.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "project" { type = string }

resource "aws_ecr_repository" "app" {
  name                 = var.project
  image_tag_mutability = "MUTABLE" # rehearsals overwrite :latest constantly

  image_scanning_configuration {
    scan_on_push = false
  }

  # The repository is torn down with the rest of the environment, and the images
  # in it are rebuilt from source in under a minute.
  force_delete = true
}

# Storage is billed per GB-month, and a fortnight of rehearsal builds adds up to
# more clutter than money. Keep the last few and let the rest go.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 5 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

output "repository_url" { value = aws_ecr_repository.app.repository_url }
output "repository_name" { value = aws_ecr_repository.app.name }
