lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'aws_helper/version'

Gem::Specification.new do |s|
  s.name          = 'aws_helper'
  s.version       = AwsHelper::VERSION
  s.date          = '2016-04-08'
  s.summary       = 'Manage AWS for DataTrue'
  s.description   = 'A simple helper gem to deploy, setup and manage the DataTrue AWS environment.'
  s.authors       = ['Thiago Figueiró']
  s.email         = 'thiagofigueiro@lens10.com.au'
  s.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  s.require_paths = ["lib"]
  s.homepage      = 'https://github.com/Lens10/aws_helper'
  s.license       = 'Proprietary'

  s.add_runtime_dependency 'aws-sdk', ['~> 2.11']
end
