# Net::SSH::CLI

Adds another layer on top of NET::SSH for a proper handling of CLI sessions which last longer than one command. This is especially usefull for enterprise Switches and Routers.

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

## Usage

```ruby

Net::SSH.start('host', 'user', password: "password") do |ssh|
  cli = ssh.open_cli_channel(default_prompt: /(\nuser@host):/m)

  #cmd
  cli.cmd ""
  # => "Last login: \nuser@host:"
  cli.cmd "echo 'bananas'"
  # => "echo 'bananas'\nbananas\nuser@host:"
end
```

### cmd
```ruby
  cli.cmd "echo 'bananas'"
  # => "echo 'bananas'\nbananas\nuser@host:"
  cli.cmd "echo 'bananas'", rm_command: true
  # => "bananas\nuser@host:"
  cli.cmd "echo 'bananas'", rm_prompt: true
  # => "echo 'bananas'\nbananas"
  cli.cmd "echo 'bananas'", rm_command: true, rm_prompt: true
  # => "bananas"
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/swisscom/net-ssh-cli.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
