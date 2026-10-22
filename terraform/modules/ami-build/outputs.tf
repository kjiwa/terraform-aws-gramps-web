output "project_name" {
  description = "CodeBuild project name. Trigger with: aws codebuild start-build --project-name <this>."
  value       = aws_codebuild_project.ami.name
}
