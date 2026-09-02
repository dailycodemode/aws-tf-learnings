# --- 1. S3 Bucket for Pipeline Artifacts ---
resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket_prefix = "tf-pipeline-artifacts-rsm"
  force_destroy = true
}

# --- 2. IAM Roles ---
# Role for CodePipeline
resource "aws_iam_role" "pipeline_role" {
  name = "terraform-pipeline-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "codepipeline.amazonaws.com" } }]
  })
}

# Role for CodeBuild (Needs permissions to manage YOUR infrastructure)
resource "aws_iam_role" "codebuild_role" {
  name = "terraform-codebuild-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "codebuild.amazonaws.com" } }]
  })
}

# Attach AdministratorAccess to CodeBuild for demo purposes (Restrict this in Production!)
resource "aws_iam_role_policy_attachment" "codebuild_admin" {
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
  role       = aws_iam_role.codebuild_role.name
}

# --- 3. CodeBuild Projects ---
resource "aws_codebuild_project" "tf_plan" {
  name          = "terraform-plan"
  service_role  = aws_iam_role.codebuild_role.arn
  artifacts     { type = "CODEPIPELINE" }
  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"
  }
  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec_plan.yml"
  }
}

resource "aws_codebuild_project" "tf_apply" {
  name          = "terraform-apply"
  service_role  = aws_iam_role.codebuild_role.arn
  artifacts     { type = "CODEPIPELINE" }
  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"
  }
  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec_apply.yml"
  }
}

resource "aws_codeconnections_connection" "github" {
  name          = "my-github-connection"
  provider_type = "GitHub"
}

resource "aws_iam_role_policy" "pipeline_connection_policy" {
  name = "codepipeline-connection-policy"
  role = aws_iam_role.pipeline_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = [
          "codestar-connections:UseConnection",
          "codeconnections:UseConnection"
        ]
        Effect   = "Allow"
        Resource = aws_codeconnections_connection.github.arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "pipeline_s3_artifacts" {
  name = "codepipeline-s3-artifacts-policy"
  role = aws_iam_role.pipeline_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetBucketVersioning",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.pipeline_artifacts.arn,
          "${aws_s3_bucket.pipeline_artifacts.arn}/*"
        ]
      }
    ]
  })
}


# explicit IAM permission to call the StartBuild API on your specific CodeBuild projects
resource "aws_iam_role_policy" "pipeline_codebuild_execution" {
  name = "codepipeline-codebuild-execution-policy"
  role = aws_iam_role.pipeline_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "codebuild:StartBuild",
          "codebuild:BatchGetBuilds"
        ]
        Resource = [
          aws_codebuild_project.tf_plan.arn,
          aws_codebuild_project.tf_apply.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "codebuild_connection_policy" {
  name = "codebuild-connection-policy"
  role = aws_iam_role.codebuild_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "codeconnections:UseConnection",
          "codestar-connections:UseConnection"
        ]
        Resource = aws_codeconnections_connection.github.arn
      }
    ]
  })
}

# --- 4. The CodePipeline ---
resource "aws_codepipeline" "terraform_pipeline" {
  name     = "terraform-deployment-pipeline"
  role_arn = aws_iam_role.pipeline_role.arn

  pipeline_type = "V2" # Upgraded to V2 for advanced features

  # Define custom pipeline variables that can be overridden when releasing a change
  variable {
    name          = "AWS_ACCOUNT"
    default_value = "."
    description   = "Target environment for deployment (e.g., staging, production)"
  }

  variable {
    name          = "GIT_TAG"
    default_value = "."
    description   = "Specific Git tag to checkout and deploy (leave blank for latest main)"
  }

  variable {
    name          = "GIT_BRANCH"
    default_value = "."
    description   = "Specific Git branch to checkout and deploy (leave blank for latest main)"
  }

  variable {
    name          = "GIT_COMMIT"
    default_value = "."
    description   = "Specific Git commit to checkout and deploy (leave blank for latest main)"
  }

  artifact_store {
    location = aws_s3_bucket.pipeline_artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn        = aws_codeconnections_connection.github.arn
        FullRepositoryId     = "dailycodemode/terraform-sandbox"
        BranchName           = "main"
        OutputArtifactFormat = "CODEBUILD_CLONE_REF"
      }
    }
  }

  stage {
    name = "Plan"
    action {
      name             = "BuildPlan"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source_output"]
      output_artifacts = ["plan_output"]
      version          = "1"

      # Pass pipeline variables into CodeBuild environment variables
      configuration = {
        ProjectName = aws_codebuild_project.tf_plan.name
        EnvironmentVariables = jsonencode([
          {
            name  = "AWS_ACCOUNT"
            value = "#{variables.AWS_ACCOUNT}"
            type  = "PLAINTEXT"
          },
          {
            name  = "GIT_BRANCH"
            value = "#{variables.GIT_BRANCH}"
            type  = "PLAINTEXT"
          },
          {
            name  = "GIT_TAG"
            value = "#{variables.GIT_TAG}"
            type  = "PLAINTEXT"
          },
          {
            name  = "GIT_COMMIT"
            value = "#{variables.GIT_TAG}"
            type  = "PLAINTEXT"
          }
        ])
      }
    }
  }

  stage {
    name = "Approval"
    action {
      name     = "ManualApproval"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"
    }
  }

  stage {
    name = "Apply"
    action {
      name            = "BuildApply"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      input_artifacts = ["plan_output"]
      version         = "1"

      # Pass pipeline variables to Apply stage as well if needed
      configuration = {
        ProjectName = aws_codebuild_project.tf_apply.name
        EnvironmentVariables = jsonencode([
          {
            name  = "AWS_ACCOUNT"
            value = "#{variables.AWS_ACCOUNT}"
            type  = "PLAINTEXT"
          },
          {
            name  = "GIT_TAG"
            value = "#{variables.GIT_TAG}"
            type  = "PLAINTEXT"
          }
        ])
      }
    }
  }
}