class AwsHelper
  PROJECT_TAG             = 'tagtrue'
  RAILS_ENV               = ENV['RAILS_ENV'] || 'development'
  METADATA_URI            = URI.parse('http://169.254.169.254/latest/meta-data')
  WORKER_INSTANCE_LIMIT   = 'production'.eql?(RAILS_ENV) ? 10 : 4
  WORKERS_PER_INSTANCE    = 'development'.eql?(RAILS_ENV) ? 1 : 4
  CONFIG_NAME_BASE        = "ttworker_#{RAILS_ENV}_"
  AMI_NAME_BASE           = 'tagtrue_worker_v'
  # When rebooting instances, wait for this percentage to come back before batch rebooting.
  REBOOT_WAIT_COUNT_PCT   = 0.5
  REBOOT_TIMEOUT          = 120 # seconds
  INSTANCE_STARTUP_TIME   = 250 # seconds - measured at 220s so add a bit of room.
  AWS_OBJECT_CLEANUP_AGE  = 30 # days
end
