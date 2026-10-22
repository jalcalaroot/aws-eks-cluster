output "ci_agent_role_arn" {
  value = aws_iam_role.ci_agent.arn
}

output "ci_plan_role_arn" {
  value = aws_iam_role.ci_plan.arn
}
