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
  cli = ssh.open_cli_channel(default_prompt: /(\nuser@host):/m)
  cli.cmd ""
  # => "Last login: \nuser@host:"

  cli.cmd "echo 'bananas'"
  # => "echo 'bananas'\nbananas\nuser@host:"
end
```

```ruby
  net_ssh = Net::SSH.start('host', 'user', password: "password")
  cli = Net::SSH::CLI::Channel.new(net_ssh: net_ssh)
  cli.cmd ""
```

```ruby
  cli = Net::SSH::CLI::Channel.new(net_ssh_options: {host: 'host', user: 'user', password: 'password'})
  cli.cmd ""
```

### #cmd
```ruby
  cli = ssh.open_cli_channel(default_prompt: /(\nuser@host):/m)
  cli.cmd "echo 'bananas'"
  # => "echo 'bananas'\nbananas\nuser@host:"
  cli.cmd "echo 'bananas'", rm_command: true
  # => "bananas\nuser@host:"
  cli.cmd "echo 'bananas'", rm_prompt: true
  # => "echo 'bananas'\nbananas"
  cli.cmd "echo 'bananas'", rm_command: true, rm_prompt: true
  # => "bananas"
```

Remove the command and the prompt for #cmd & #dialog by default
```ruby
  cli = ssh.open_cli_channel(default_prompt: /(\nuser@host):/m, cmd_rm_command: true, cmd_rm_prompt: true)
  cli.cmd "echo 'bananas'"
  # => "bananas"
```

### #dialog
```ruby
  cli.dialog "echo 'are you sure?' && read -p 'yes|no>'", /\nyes|no>/
  # => "echo 'are you sure?' && read -p 'yes|no>'\nyes|no>"
  cli.cmd "yes"
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/swisscom/net-ssh-cli.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
