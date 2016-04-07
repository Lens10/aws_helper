class AwsHelper
  require 'aws_helper/client.rb'
  require 'net/http'

  PROJECT_TAG = 'tagtrue'
  RAILS_ENV = ENV['RAILS_ENV'] || 'development'
  METADATA_URI = URI.parse('http://169.254.169.254/latest/meta-data')
  WORKER_INSTANCE_LIMIT = 'production'.eql?(RAILS_ENV) ? 10 : 4
  CONFIG_NAME_BASE = "ttworker_#{RAILS_ENV}_"
  # When rebooting instances, wait for this percentage to come back before batch rebooting.
  REBOOT_WAIT_COUNT_PCT = 0.5
  REBOOT_TIMEOUT = 60 # seconds
  INSTANCE_STARTUP_TIME = 240 # seconds - measured at 220s so add a bit of room.

# TODO: convert puts to Logger

  def initialize
    @@client = AwsHelper::Client.new
  end

  def reboot_instances
    target_instances = get_running_worker_instances
    wait_instance_count = (target_instances.count*REBOOT_WAIT_COUNT_PCT).to_i

    puts "Found [#{target_instances.count}] [#{RAILS_ENV}] instance(s) of [#{PROJECT_TAG}] to reboot."

    if target_instances.count == 0
      puts "No target instances found."
      exit 0
    elsif target_instances.count == 1
      add_instances(1)
      puts "Added one new instance. Sleeping for #{INSTANCE_STARTUP_TIME}s before rebooting existing instance."
      for i in 0..INSTANCE_STARTUP_TIME
        print "\r#{i}..."
        sleep 1
      end
    else
      puts "Waiting for [#{wait_instance_count}] instance(s) to reboot before rebooting the remainder without delay."
    end

    i = 0
    target_instances.each do |instance|
      if wait_instance_count > i
        puts "Stopping #{instance.id} (#{instance.tags['Name']},#{instance.private_ip_address}).\n"
        if instance_stop_and_wait(instance, REBOOT_TIMEOUT)
          puts "  timed-out after #{REBOOT_TIMEOUT} seconds."
          exit 1
        end

        puts  "  starting #{instance.id}.\n"
        if instance_start_and_wait(instance, REBOOT_TIMEOUT)
          puts "  timed-out after #{REBOOT_TIMEOUT} seconds."
          exit 1
        else
          puts "  state of #{instance.id} changed to running.\n"
        end
      else
        puts  "Rebooting #{instance.id} (#{instance.tags['Name']},#{instance.private_ip_address}).\n"
        instance.reboot
      end
      i += 1
    end
  end

  def get_self_instance_id
    begin
      http = Net::HTTP.new(METADATA_URI.host, METADATA_URI.port)
      http.open_timeout = 1
      http.read_timeout = 1
      http.get("#{METADATA_URI.path}/instance-id").body
    rescue Net::OpenTimeout
      "NOT_AN_EC2_INSTANCE"
    end
  end

  def get_leader_instance_id
    instances = get_running_worker_instances
    instances.map(&:id).sort[0]
  end

  # v2 of aws-sdk has built-in wait states but v1 doesn't :(
  def instance_stop_and_wait(instance, timeout=60)
    instance.stop

    j = 0
    until instance.status == :stopped || j > timeout
      sleep(1)
      j += 1
    end

    return j > timeout
  end

  def instance_start_and_wait(instance, timeout=60)
    instance.start

    j = 0
    until instance.status == :running || j > timeout
      sleep(1)
      j += 1
    end

    return j > timeout
  end

  def add_instances(num)
    resp = @@client.autoscale.describe_auto_scaling_groups()
    resource_name = ""
    desired_capacity = 0

    resp.auto_scaling_groups.each do |group|
      resource_name = group.launch_configuration_name
      desired_capacity = group.desired_capacity
      break if resource_name.start_with?(CONFIG_NAME_BASE)
    end

    if resource_name.start_with?(CONFIG_NAME_BASE)
      if desired_capacity == WORKER_INSTANCE_LIMIT
        Rails.logger.error "Limit of #{WORKER_INSTANCE_LIMIT} reached; not scaling-up."
        return WORKER_INSTANCE_LIMIT
      end

      desired_capacity += num
      if desired_capacity > WORKER_INSTANCE_LIMIT
        Rails.logger.warn "Desired capacity of #{desired_capacity} limited to #{WORKER_INSTANCE_LIMIT}."
        desired_capacity = WORKER_INSTANCE_LIMIT
      end

      Rails.logger.info "Setting desired capacity to #{desired_capacity} instances."

      autoscale.set_desired_capacity(
        auto_scaling_group_name: resource_name,
        desired_capacity: desired_capacity
      )

      return desired_capacity
    else
      Rails.logger.error "Could not find an autoscale group name starting with [#{CONFIG_NAME_BASE}]."
    end
  end

  def create_launch_configuration(ami_id)
    launch_configuration_name = get_available_launch_configuration_name(autoscale)

    @@client.autoscale.create_launch_configuration({
      launch_configuration_name: launch_configuration_name,
      key_name: "id_lens10",
      security_groups: ["sg-57142f2e"],
      image_id: ami_id,
      instance_type: "t2.large",
      instance_monitoring: {
        enabled: false,
      },
      ebs_optimized: false,
      associate_public_ip_address: false,
      placement_tenancy: "default"
    })

    return launch_configuration_name
  end

  def create_autoscale_group(ami_id)
    launch_configuration_name = create_launch_configuration(ami_id)
    autoscale_group_name = get_available_scaling_group_name

    @@client.autoscale.create_auto_scaling_group ({
      auto_scaling_group_name: autoscale_group_name,
      launch_configuration_name: launch_configuration_name,
      min_size: 1,
      desired_capacity: 1,
      max_size: WORKER_INSTANCE_LIMIT,
      health_check_grace_period: 300,
      # It's not worth automating these options until we need larger scale.
      # When we require need another region, I would start with a simple map of
      # values for each region; e.g.:
      # availability_zones = AWS_CONFIG[ENV['DEPLOY_AWS_REGION']].availability_zones
      # vpc_zone_identifier = AWS_CONFIG[ENV['DEPLOY_AWS_REGION']].vpc_zone_identifier
      availability_zones: ['us-east-1d'],
      vpc_zone_identifier: 'subnet-7486405f',
      tags: [{ key: 'Name', value: "tagtrue-#{RAILS_ENV}-autoscale", propagate_at_launch: true },
             { key: 'environment', value: RAILS_ENV, propagate_at_launch: true },
             { key: 'project', value: 'tagtrue', propagate_at_launch: true }]
    })

    configure_autoscale_policies(autoscale_group_name)

    return autoscale_group_name
  end

  def get_available_launch_configuration_name(autoscale)
    i = 1
    launch_configuration_name = "#{CONFIG_NAME_BASE}#{Date.today.iso8601}_#{i}"
    lc = autoscale.describe_launch_configurations({launch_configuration_names: [launch_configuration_name]})
    until 0 == lc.launch_configurations.count
      i += 1
      launch_configuration_name = "#{CONFIG_NAME_BASE}#{Date.today.iso8601}_#{i}"
      lc = autoscale.describe_launch_configurations({launch_configuration_names: [launch_configuration_name]})
    end

    return launch_configuration_name
  end

  def get_available_scaling_group_name
    i = 1
    scaling_group_name = "#{CONFIG_NAME_BASE}#{Date.today.iso8601}_#{i}"
    sg = @@client.autoscale.describe_auto_scaling_groups({auto_scaling_group_names: [scaling_group_name]})
    until 0 == sg.auto_scaling_groups.count
      i += 1
      scaling_group_name = "#{CONFIG_NAME_BASE}#{Date.today.iso8601}_#{i}"
      sg = @@client.autoscale.describe_auto_scaling_groups({auto_scaling_group_names: [scaling_group_name]})
    end

    return scaling_group_name
  end

  def configure_autoscale_policies(group_name)
    scale_up_arn = @@client.autoscale.put_scaling_policy({
      auto_scaling_group_name: group_name,
      policy_name: "#{CONFIG_NAME_BASE}_scale_up_policy",
      scaling_adjustment: 3,
      adjustment_type: "ChangeInCapacity",
      cooldown: 60
    })[:policy_arn]

    scale_down_arn = @@client.autoscale.put_scaling_policy({
      auto_scaling_group_name: group_name,
      policy_name: "#{CONFIG_NAME_BASE}_scale_down_policy",
      scaling_adjustment: -2,
      adjustment_type: "ChangeInCapacity",
      cooldown: 60
    })[:policy_arn]

    @@client.cloudwatch.put_metric_alarm({
      :alarm_name => "#{CONFIG_NAME_BASE}_scale_up_policy_alarm",
      :actions_enabled => true,
      :alarm_actions => [scale_up_arn],
      :metric_name => "CPUUtilization",
      :namespace => "AWS/EC2",
      :statistic => "Average",
      :dimensions => [{:name => "AutoScalingGroupName",:value => group_name}],
      :evaluation_periods=>2,
      :period=>300,
      :threshold=>50.0,
      :comparison_operator=>"GreaterThanOrEqualToThreshold"
    })

    @@client.cloudwatch.put_metric_alarm({
      :alarm_name => "#{CONFIG_NAME_BASE}_scale_down_policy_alarm",
      :actions_enabled => true,
      :alarm_actions => [scale_down_arn],
      :metric_name => "CPUUtilization",
      :namespace => "AWS/EC2",
      :statistic => "Average",
      :dimensions => [{:name => "AutoScalingGroupName",:value => group_name}],
      :period=>300,
      :evaluation_periods=>1,
      :threshold=>20.0,
      :comparison_operator=>"LessThanOrEqualToThreshold"
    })
  end

private
  def get_running_worker_instances
    all_running_instances = @@client.ec2.instances.filter('instance-state-name', 'running')
    running_worker_instances = all_running_instances.with_tag('project', PROJECT_TAG).with_tag('environment', RAILS_ENV)
  end

end
