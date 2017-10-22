require 'rubygems'
require 'json'
# Example code only. This file is not meant to be executed. Note we can get into
# loops here if new instances fail to register or old instances fail to deregister.

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


loop do
  elb_instances=JSON.parse(`aws elb describe-instance-health --load-balancer-name #{elb_name} --output json`)['InstanceStates']
  old_stack_instances=[]
  new_stack_instances=[]

  elb_instances.each {|instance|
    instance_name=''
    JSON.parse(`aws ec2 describe-instances --instance-ids #{instance['InstanceId']}`)['Reservations'][0]['Instances'][0]['Tags'].each {|tag|
      if tag['Key'] == "Name"

       instance_name = tag['Value']
      end
    }
    if instance_name == stack_name
      new_stack_instances << instance['InstanceId']
      puts "NEW instance: "+instance['InstanceId']
    else
      old_stack_instances << instance['InstanceId']
      puts "OLD instance: "+instance['InstanceId']
    end
  }

  num = 0
  new_stack_instances.each {|instance_id|
    elb_instances.each {|instance|
      if ( instance['InstanceId'] == instance_id )
        puts instance_id+' - '+instance['State']

        if ( instance['State'] == 'InService' )
          num+=1
        end
      end
    }
  }

  if num.to_i == expect.to_i
    puts "New instances: #{new_stack_instances.join(" ")}  #{num}"

    if old_stack_instances.size > 0
      puts "Old instances: #{old_stack_instances.join(" ")}"
      system("aws elb deregister-instances-from-load-balancer --load-balancer-name #{elb_name} --instances #{old_stack_instances.join(' ')}")
      puts "Old instances was deregistered from elb"
    else
      puts "There were no old instances to deregister"
    end

    # We do exit here
    break
  end

  puts "Another check in 5 seconds"
  sleep(5)
end
