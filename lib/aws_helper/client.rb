class AwsHelper::Client
  require 'aws-sdk-v1'
  require 'net/http'

  attr_reader :autoscale, :cloudwatch, :ec2

  def initialize(h = {})
    @@aws_options = {
      access_key_id:      h[:access_key_id]     || ENV['AWS_ACCESS_KEY_ID'],
      secret_access_key:  h[:secret_access_key] || ENV['AWS_SECRET_ACCESS_KEY'],
      region:             h[:region]            || ENV['AWS_REGION'] || 'us-east-1'
    }

    @ec2         = get_ec2_client
    @autoscale   = get_autoscale_client
    @cloudwatch  = get_cloudwatch_client
  end

private
  def get_ec2_client
    AWS::EC2.new(@@aws_options)
  end

  def get_autoscale_client
    AWS::AutoScaling::Client.new(@@aws_options)
  end

  def get_cloudwatch_client
    AWS::CloudWatch::Client::new(@@aws_options)
  end
end
