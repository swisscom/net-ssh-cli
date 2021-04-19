# Net::SSH::CLI

Adds another layer on top of Net::SSH for a proper handling of CLI sessions which last longer than one command. This is especially usefull for enterprise Switches and Routers.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'net-ssh-cli'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install net-ssh-cli

## Features

 - provides an abstraction on top of the text-stream of a long living CLI sessions
 - tries to be highly configurable
 - has methods like #cmd and #dialog for common usecases
 - offers waiting operations like #read_till

## Usage

```ruby
Net::SSH.start('host', 'user', password: "password") do |ssh|
  cli = ssh.cli(default_prompt: /(\nuser@host):/m)
  cli.cmd ""
  # => "Last login: \nuser@host:"

  cli.cmd "echo 'bananas'"
  # => "echo 'bananas'\nbananas\nuser@host:"
end
```

```ruby
  net_ssh = Net::SSH.start('host', 'user', password: "password")
  cli = Net::SSH::CLI::Session.new(net_ssh: net_ssh)
  cli.cmd ""
```

```ruby
  cli = Net::SSH::CLI::Session.new(net_ssh_options: {host: 'host', user: 'user', password: 'password'})
  cli.cmd ""
```

### #cmd
```ruby
  cli = ssh.cli(default_prompt: /(\nuser@host):/m)
  cli.cmd "echo 'bananas'"
  # => "echo 'bananas'\nbananas\nuser@host:"
  cli.cmd "echo 'bananas'", rm_command: true
  # => "bananas\nuser@host:"
  cli.cmd "echo 'bananas'", rm_prompt: true
  # => "echo 'bananas'\nbananas"
  cli.cmd "echo 'bananas'", rm_command: true, rm_prompt: true
  # => "bananas"
  cli.cmd "echo 'bananas'", rm_command: true, rm_prompt: true, minimum_duration: 9
  # => "bananas"
  cli.cmd "echo 'bananas'", rm_command: true, rm_prompt: true, prompt: /\nuser@host:/m
  # => "bananas"
  cli.cmd "echo 'bananas'", rm_command: true, rm_prompt: true, timeout: 60
  # => "bananas"
```

Remove the command and the prompt for #cmd & #dialog by default
```ruby
  cli = ssh.cli(default_prompt: /(\nuser@host):/m, cmd_rm_command: true, cmd_rm_prompt: true)
  cli.cmd "echo 'bananas'"
  # => "bananas"
```

You can define a timeout for a `#cmd` in order to avoid hanging commands. The timeout gets passed into the underlying function #read_till.
This is usefull in case your prompt won't match because of an unexpected behaviour or undefined behaviour. For example some form of unexpected dialog. 
The underlying implementation is using a soft timeout because `Timeout.timeout` is dangerous. In order to deal anyway with hanging low level issues, `Timeout.timeout` is used too, but with a higher value than the soft timeout.

```ruby
  cli = ssh.cli(default_prompt: /(\nuser@host):/m, read_till_timeout: 11)
  cli.cmd "echo 'bananas'"                      # timeout is set to 11
  # => "bananas"
  cli.cmd "echo 'bananas'", timeout: 22         # timeout is set to 22
  # => "bananas"
  cli.cmd "sleep 33", timeout: 22               # timeout is set to 22
  # Net::SSH::CLI::Error::CMD
```

### #cmds

It's the same as `#cmd` but for multiple commands.

```ruby
  cli.cmds ["echo 'bananas'", "echo 'apples'"], rm_command: true, rm_prompt: true
  # => ["bananas", "apples"]
```

### #dialog

Use this method to specify a differnt 'prompt' for once. This is perfect for interactive commands. 

```ruby
  cli.dialog "echo 'are you sure?' && read -p 'yes|no>'", /\nyes|no>/
  # => "echo 'are you sure?' && read -p 'yes|no>'\nyes|no>"
  cli.cmd "yes"
```

```ruby
cli.dialog "passwd", /Current Password:/i
cli.dialog "Old Password", /New Password:/i
cli.dialog "New Password", /Repeat Password:/i
cli.cmd "New Password"
```

### #impact

The very same as `#cmd` but it respects a flag whether to run commands with 'impact'.
This can be used in a setup where you don't want to run certain commands under certain conditions.
For example in testing. 

```ruby
  cli.run_impact?
  # => false
  cli.impact "reboot now"
  # => "skip: 'reboot now'"
```

```ruby
  cli.run_impact = true
  cli.impact "reboot now"
  # => connection closed
```

### #read & #write

```ruby
  cli.write "echo 'hello'\n"
  # => "echo 'hello'\n"
  cli.read
  # => "echo 'hello'\nhello\nuser@host:"
```

### #write_n
```ruby
  cli.write_n "echo 'hello'"
  # => "echo 'hello'\n"
```

### #read_till
keep on processing till the stdout matches to given|default prompt and then read the whole stdin.
```ruby
  cli.write "echo 'hello'\n"
  # => "echo 'hello'\n"
  cli.read_till
  # => "echo 'hello'\nhello\nuser@host:"
```

This method is used by #cmd, see ``lib/net/ssh/cli.rb#cmd``

### #read_for

```ruby
  cli.write_n "sleep 180"
  # => ""
  cli.read_for(seconds: 181)
  # => "..."
```

## Configuration

Have a deep look at the various Options configured by ``Net::SSH::CLI::OPTIONS`` in ``lib/net/ssh/cli.rb``
Nearly everything can be configured.


### Callbacks

The following callbacks are available
 - before_open_channel
 - after_open_channel
 - before_on_stdout
 - after_on_stdout
 - before_on_stdin
 - after_on_stdin

```ruby
cli.before_open_channel do
  puts "The channel will open soon"
end
```

```ruby
cli.after_open_channel do
  cmd "logger 'Net::SSH::CLI works'"
  cmd "sudo -i"
end
```

Using the callbacks you can define a debugger which shows the `stdout` buffer content each time new data is received.

```ruby
cli.after_on_stdout do
  warn stdout
end
```

```ruby
cli.after_on_stdout do
  puts "the following new data arrived on stdout #{new_data.inspect} from #{hostname}"
end
```

or convert new lines between different OS
```ruby
cli.after_on_stdout do
  stdout.gsub!("\r\n", "\n")
end
```

or hide passwords
```ruby
cli.after_on_stdout do
  stdout.gsub!(/password:\S+/, "<HIDDEN>")
end
```

or change the stdin before sending it
```ruby
cli.before_on_stdin do
  content.gsub("\n\n", "\n")
end
```

### #hostname #host #to_s

```ruby
  cli.to_s
  # => "localhost"
  cli.hostname
  # => "localhost"
  cli.host
  # => "localhost"
```

### #detect_prompt

NET::SSH::CLI can try to guess the prompt by waiting for it and using the last line.
This works usually, but is not guaranteed to work well.

```ruby
  cli.open_channel
  # => ...
  cli.detect_prompt(seconds: 3)
  # => "[my prompt]"
```

### An outdated view of all available Options

Please check the file `lib/net/ssh/cli.rb` `OPTIONS` in order to get an up-to-date view of all available options, flags and arguments.

```ruby
      OPTIONS = ActiveSupport::HashWithIndifferentAccess.new(
        default_prompt:            /\n?^(\S+@.*)\z/,                             # the default prompt to search for
        cmd_rm_prompt:             false,                                        # whether the prompt should be removed in the output of #cmd
        cmd_rm_command:            false,                                        # whether the given command should be removed in the output of #cmd
        cmd_rm_command_tail:       "\n",                                         # which format does the end of line return after a command has been submitted. Could be something like "ls\n" "ls\r\n" or "ls \n" (extra spaces)
        run_impact:                false,                                        # whether to run #impact commands. This might align with testing|development|production. example #impact("reboot")
        read_till_timeout:         nil,                                          # timeout for #read_till to find the match
        read_till_hard_timeout:    nil,                                          # hard timeout for #read_till to find the match using Timeout.timeout(hard_timeout) {}. Might creates unpredicted sideffects
        read_till_hard_timeout_factor: 1.2,                                      # hard timeout factor in case read_till_hard_timeout is true
        named_prompts:             ActiveSupport::HashWithIndifferentAccess.new, # you can used named prompts for #with_prompt {} 
        before_cmd_procs:          ActiveSupport::HashWithIndifferentAccess.new, # procs to call before #cmd 
        after_cmd_procs:           ActiveSupport::HashWithIndifferentAccess.new, # procs to call after  #cmd
        before_on_stdout_procs:    ActiveSupport::HashWithIndifferentAccess.new, # procs to call before data arrives from the underlying connection 
        after_on_stdout_procs:     ActiveSupport::HashWithIndifferentAccess.new, # procs to call after  data arrives from the underlying connection
        before_on_stdin_procs:     ActiveSupport::HashWithIndifferentAccess.new, # procs to call before data is sent to the underlying channel 
        after_on_stdin_procs:      ActiveSupport::HashWithIndifferentAccess.new, # procs to call after  data is sent to the underlying channel
        before_open_channel_procs: ActiveSupport::HashWithIndifferentAccess.new, # procs to call before opening a channel 
        after_open_channel_procs:  ActiveSupport::HashWithIndifferentAccess.new, # procs to call after  opening a channel, for example you could call #detect_prompt or #read_till
        open_channel_timeout:      nil,                                          # timeout to open the channel
        net_ssh_options:           ActiveSupport::HashWithIndifferentAccess.new, # a wrapper for options to pass to Net::SSH.start in case net_ssh is undefined
        process_time:              0.00001,                                      # how long #process is processing net_ssh#process or sleeping (waiting for something)
        background_processing:     false,                                        # default false, whether the process method maps to the underlying net_ssh#process or the net_ssh#process happens in a separate loop
        on_stdout_processing:      100,                                          # whether to optimize the on_stdout performance by calling #process #optimize_on_stdout-times in case more data arrives
        sleep_procs:               ActiveSupport::HashWithIndifferentAccess.new, # procs to call instead of Kernel.sleep(), perfect for async hooks
      )
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/swisscom/net-ssh-cli.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
