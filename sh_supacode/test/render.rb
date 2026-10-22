#!/usr/bin/env ruby
require "erb"
require "json"
require "ostruct"
require "yaml"

class Context < OpenStruct
  def context
    self
  end

  def render_binding
    binding
  end
end

path, values, format = ARGV
renderer = ERB.new(File.read(path), trim_mode: "-")
renderer.filename = path
output = renderer.result(Context.new(JSON.parse(values)).render_binding)
puts(format == "yaml" ? JSON.generate(YAML.safe_load(output)) : output)
