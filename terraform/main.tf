resource "aws_s3_bucket" "static_web" {
  bucket        = "${var.env}-grp2-final-bkt"
  force_destroy = true
}

resource "aws_s3_bucket_policy" "allow_access_from_cloudfront" {
  bucket = aws_s3_bucket.static_web.id
  policy = data.aws_iam_policy_document.default.json
}

resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name              = aws_s3_bucket.static_web.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
    origin_id                = "origin-${aws_s3_bucket.static_web.id}"
  }
    web_acl_id = aws_wafv2_web_acl.cert.arn

  aliases = var.aliases

  enabled             = true
  comment             = "Static Website using S3 and Cloudfront OAC in ${var.env} environment"
  default_root_object = "index.html"

  default_cache_behavior {
    cache_policy_id        = data.aws_cloudfront_cache_policy.example.id
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "origin-${aws_s3_bucket.static_web.id}"
    viewer_protocol_policy = "allow-all"
  }

  viewer_certificate {
    acm_certificate_arn = var.acm_certificate_arn
    ssl_support_method  = "sni-only"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
      locations        = []
    }
  }
}

resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "${aws_s3_bucket.static_web.id}-oac-${var.env}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_acm_certificate" "cert" {
  domain_name       = "berryfresh.com"
  validation_method = "DNS"  # or "EMAIL"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_wafv2_web_acl" "cert" {
  name        = "group2-waf"
  description = "WAF for CloudFront"
  scope       = "CLOUDFRONT"  # Change this to CLOUDFRONT

  default_action {
    allow {}
  }

  rule {
    name     = "example-rule"
    priority = 1
    action {
      block {}
    }

    statement {
      byte_match_statement {
        search_string = "bad-request"
        field_to_match {
          uri_path {}
        }

        # Use 'text_transformation' instead of 'text_transformations'
        text_transformation {
          priority = 0
          type     = "NONE"  # No transformation applied to the search string
        }

        positional_constraint = "CONTAINS"  # Look for 'bad-request' anywhere in the path
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "waf-example"
      sampled_requests_enabled    = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "example-acl"
    sampled_requests_enabled    = true
  }
}

#DynamoDB

resource "aws_dynamodb_table" "product_table" {
  name         = "PRODUCT"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "product_id"
  attribute {
    name = "product_id"
    type = "S"
  }
  attribute {
    name = "category"
    type = "S"
  }
  attribute {
    name = "product_rating"
    type = "N"
  }
  global_secondary_index {
    name            = "ProductCategoryRatingIndex"
    hash_key        = "category"
    range_key       = "product_rating"
    projection_type = "ALL"
  }
}

#API Gateway

resource "aws_api_gateway_rest_api" "product_apigw" {
  name        = "product_apigw"
  description = "Product API Gateway"
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}
resource "aws_api_gateway_resource" "product" {
  rest_api_id = aws_api_gateway_rest_api.product_apigw.id
  parent_id   = aws_api_gateway_rest_api.product_apigw.root_resource_id
  path_part   = "product"
}
resource "aws_api_gateway_method" "createproduct" {
  rest_api_id   = aws_api_gateway_rest_api.product_apigw.id
  resource_id   = aws_api_gateway_resource.product.id
  http_method   = "POST"
  authorization = "NONE"
}

#Lambda IAM

resource "aws_iam_role" "ProductLambdaRole" {
  name               = "ProductLambdaRole"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

locals {
  actions = [
    "logs:CreateLogStream",
    "logs:CreateLogGroup",
    "logs:PutLogEvents"
  ]
  productlambdapolicy = templatefile("/Users/Benjamin.Paton/ce6final/terraform/policy.json", {
        var1 = join(", ", local.actions)  # Joining the array into a comma-separated string
        var2 = "arn:aws:logs:*:*:*"
  })
  }
resource "aws_iam_policy" "ProductLambdaPolicy" {
  name        = "ProductLambdaPolicy"
  path        = "/"
  description = "IAM policy for Product lambda functions"
  policy      = local.productlambdapolicy
}
resource "aws_iam_role_policy_attachment" "ProductLambdaRolePolicy" {
  role       = aws_iam_role.ProductLambdaRole.name
  policy_arn = aws_iam_policy.ProductLambdaPolicy.arn
}

#Lambda 1

resource "aws_lambda_function" "CreateProductHandler" {
  function_name = "CreateProductHandler"
  filename = "terraform/product_lambda.zip"
  handler = "createproduct.lambda_handler"
  runtime = "python3.8"
  environment {
    variables = {
      REGION        = "ap-southeast-1"
      PRODUCT_TABLE = aws_dynamodb_table.product_table.name
   }
  }
  source_code_hash = filebase64sha256("/Users/Benjamin.Paton/ce6final/terraform/product_lambda.zip")
  role = aws_iam_role.ProductLambdaRole.arn
  timeout     = "5"
  memory_size = "128"
}

#Connecting API Gateway to Lambda 1

resource "aws_api_gateway_integration" "createproduct-lambda" {
rest_api_id = aws_api_gateway_rest_api.product_apigw.id
  resource_id = aws_api_gateway_method.createproduct.resource_id
  http_method = aws_api_gateway_method.createproduct.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
uri = aws_lambda_function.CreateProductHandler.invoke_arn
}
resource "aws_lambda_permission" "apigw-CreateProductHandler" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.CreateProductHandler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn = "${aws_api_gateway_rest_api.product_apigw.execution_arn}/*/POST/product"
}
resource "aws_api_gateway_deployment" "productapistageprod" {
  depends_on = [
    aws_api_gateway_integration.createproduct-lambda
  ]
  rest_api_id = aws_api_gateway_rest_api.product_apigw.id
  stage_name  = "prod"
}
