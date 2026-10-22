output "pipeline_name" {
  description = "CodePipeline name. Trigger with: scripts/deploy.sh gramps."
  value       = aws_codepipeline.this.name
}

output "build_project_name" {
  description = "CodeBuild project name (build stage)."
  value       = aws_codebuild_project.build.name
}
