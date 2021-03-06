class AwsHelper::Client
  require 'aws-sdk-ec2'
  require 'aws-sdk-cloudwatch'
  require 'aws-sdk-autoscaling'
  require 'net/http'

  attr_reader :autoscale, :cloudwatch, :ec2, :availability_zones, :vpc_zone_identifier,
              :security_groups

  def initialize(h = {})
    @aws_options = {
      access_key_id:        h[:access_key_id]       || ENV['AWS_ACCESS_KEY_ID'],
      secret_access_key:    h[:secret_access_key]   || ENV['AWS_SECRET_ACCESS_KEY'],
      region:               h[:region]              || ENV['AWS_REGION'] || 'us-east-1',
    }

    @availability_zones = h[:availability_zones] || ['us-east-1d']
    @vpc_zone_identifier = h[:vpc_zone_identifier] || 'subnet-7486405f'
    @security_groups = h[:security_groups] || ['sg-57142f2e']
    @ec2 = get_ec2_client
    @autoscale = get_autoscale_client
    @cloudwatch = get_cloudwatch_client
  end

  def get_aws_options
    @aws_options
  end

private
  def get_ec2_client
    Aws::EC2::Client.new(@aws_options)
  end

  def get_autoscale_client
    Aws::AutoScaling::Client.new(@aws_options)
  end

  def get_cloudwatch_client
    Aws::CloudWatch::Client::new(@aws_options)
  end
end
