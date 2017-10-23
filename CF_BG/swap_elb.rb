require 'rubygems'
require 'json'

# This script detatches the GREEN ASG from it's ELB and connects it to the BLUE ELB.
# Then it detaches the BLUE ASG from the BLUE ELB. End state is an unattached BLUE ASG
# and the GREEN ASG connected to the BLUE ELB. From there we can either destroy the old
# BLUE ASG or roll back to BLUE in case of any issues.
# ---------------------------------------------------------------------------
# Setup.
# ---------------------------------------------------------------------------
#
if ARGV.size != 3
  puts "Usage: script_name <elb_name> <stack_name> <expected_number_of_instances>"
  exit 1
end

elb_name = ARGV[0]
stack_name = ARGV[1]
expect = ARGV[2]
elb_green = "elb-" + "#{elb_name}" + "-green"
aws_failure = 0

# Get blue and green instances
green_instances=JSON.parse(`aws elb describe-instance-health --load-balancer-name #{elb_green} --output json`)['InstanceStates']
blue_instances=JSON.parse(`aws elb describe-instance-health --load-balancer-name #{elb_name} --output json`)['InstanceStates']
blue_stack_instances=[]
green_stack_instances=[]

green_instances.each {|instance|
  green_stack_instances << instance['InstanceId']
  puts "GREEN instance: "+instance['InstanceId']
}

blue_instances.each {|instance|
  blue_stack_instances << instance['InstanceId']
  puts "BLUE instance: "+instance['InstanceId']
}
# debug line
puts blue_stack_instances[0]
# Get ASG names
blue_asg=JSON.parse(`aws autoscaling describe-auto-scaling-instances --instance-ids #{blue_stack_instances[0]} --output json`)['AutoScalingInstances']
blue_asg_name = blue_asg.first['AutoScalingGroupName']

green_asg=JSON.parse(`aws autoscaling describe-auto-scaling-instances --instance-ids #{green_stack_instances[0]} --output json`)['AutoScalingInstances']
green_asg_name = green_asg.first['AutoScalingGroupName']

# Detach green ASG from green elb and connect to blue elb
system("aws autoscaling detach-load-balancers --auto-scaling-group-name #{green_asg_name} --load-balancer-names #{elb_green}")

i = 0
while (green_instances.size > 0) && i < 10
  puts "Waiting for GREEN ASG to detatch ... check again in 30 seconds"
  green_instances=JSON.parse(`aws elb describe-instance-health --load-balancer-name #{elb_green} --output json`)['InstanceStates']
  sleep(30)
  i += 1
end

# Check to see if Green ASG detached or we timed out
if green_instances.size == 0
  puts "GREEN ASG detached from #{elb_green}"
else
  puts "Timeout waiting from GREEN ASG to detatch. Deploy failure."
  aws_failure = 1
end

# Attach Green ASG to Blue ELB
if aws_failure == 0
  old_blue_stack_instances = blue_stack_instances.uniq
  system("aws autoscaling attach-load-balancers --auto-scaling-group-name #{green_asg_name} --load-balancer-names #{elb_name}")
  i = 0
  while ((blue_stack_instances & green_stack_instances).empty? == true) && (i < 15)
    blue_instances=JSON.parse(`aws elb describe-instance-health --load-balancer-name #{elb_name} --output json`)['InstanceStates']
    blue_instances.each {|instance|
      blue_stack_instances << instance['InstanceId']
    }
    puts "Waiting for GREEN ASG to attach to #{elb_name}"
    puts "Checking again in 30 seconds."
    i += 1
    sleep(30)
  end

# Check to see if Green ASG connected or timed out
  if (blue_stack_instances & green_stack_instances).empty? == false
    puts "GREEN ASG attached to #{elb_name}"
  else
    puts "GREEN ASG FAILED TO ATTACH to #{elb_name}. Deploy failure."
    aws_failure = 1
  end

# Detach Blue ASG
  if aws_failure == 0
    system("aws autoscaling detach-load-balancers --auto-scaling-group-name #{blue_asg_name} --load-balancer-names #{elb_name}")
    puts "Current BLUE STACK"
    puts blue_stack_instances
    puts "OLD BLUE STACK"
    puts old_blue_stack_instances
    i = 0
    while ((blue_stack_instances & old_blue_stack_instances).empty? == false) && (i < 15)
#      puts (blue_stack_instances & old_blue_stack_instances).empty? # Debug
      blue_instances=JSON.parse(`aws elb describe-instance-health --load-balancer-name #{elb_name} --output json`)['InstanceStates']
      blue_stack_instances=[]
      blue_instances.each {|instance|
        blue_stack_instances << instance['InstanceId']
        puts "BLUE instance: "+instance['InstanceId']
      }
      puts "Waiting for BLUE ASG to detach from #{elb_name}"
      puts "Checking again in 30 seconds."
      i += 1
      sleep(30)
    end

# Check to see if Blue ASG detached or we timed out
    if (blue_stack_instances & old_blue_stack_instances).empty? == true
      puts "BLUE ASG detached from #{elb_name}"
    else
      puts "BLUE ASG FAILED TO DETACH from #{elb_name}. Deploy failure."
      aws_failure = 1
    end
  end
end

if aws_failure == 0
  # Change the tag of the ASG to blue
  system("aws autoscaling create-or-update-tags --tags 'ResourceId=#{green_asg_name},ResourceType=auto-scaling-group,Key=Color,Value=blue,PropagateAtLaunch=true'")
  puts "Success"
else
  exit(1)
end
