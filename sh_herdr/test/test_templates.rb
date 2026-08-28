#!/usr/bin/env ruby

require "erb"
require "yaml"
require "minitest/autorun"

class String
  def blank?
    strip.empty?
  end
end

class NilClass
  def blank?
    true
  end
end

class TemplateBinding
  attr_accessor :herdr_session, :herdr_agents, :herdr_workspace, :sh_workspace,
                :bc_queue, :sh_cpus, :sh_mem, :bc_num_hours, :sh_modules,
                :sh_preexec, :bc_email_on_started

  def initialize(values = {})
    @herdr_session = values.fetch(:herdr_session, "sherlock")
    @herdr_agents = values.fetch(:herdr_agents, "both")
    @herdr_workspace = values.fetch(:herdr_workspace, "$HOME")
    @sh_workspace = values.fetch(:sh_workspace, "$HOME")
    @bc_queue = values.fetch(:bc_queue, "russpold")
    @sh_cpus = values[:sh_cpus]
    @sh_mem = values[:sh_mem]
    @bc_num_hours = values.fetch(:bc_num_hours, 8)
    @sh_modules = values.fetch(:sh_modules, "")
    @sh_preexec = values.fetch(:sh_preexec, "")
    @bc_email_on_started = values.fetch(:bc_email_on_started, false)
  end

  def get_binding
    binding
  end
end

class TemplateTest < Minitest::Test
  APP_ROOT = File.expand_path("../..", __dir__)

  def render(template, values = {})
    path = File.join(APP_ROOT, template)
    ERB.new(File.read(path)).result(TemplateBinding.new(values).get_binding)
  end

  def test_form_defaults_and_partition_options
    form = YAML.safe_load(render("sh_herdr/form.yml.erb"))
    assert_equal "sherlock", form.fetch("cluster")
    assert_equal %w[
      herdr_session
      herdr_agents
      sh_workspace
      bc_queue
      sh_cpus
      sh_mem
      bc_num_hours
      sh_modules
      sh_preexec
      bc_email_on_started
    ], form.fetch("form")
    assert_equal "sherlock", form.dig("attributes", "herdr_session", "value")
    assert_equal "both", form.dig("attributes", "herdr_agents", "value")
    assert_equal [["Both", "both"], ["Claude", "claude"], ["Codex", "codex"], ["None", "none"]],
                 form.dig("attributes", "herdr_agents", "options")
    assert_equal "russpold", form.dig("attributes", "bc_queue", "value")
    assert_equal [["russpold", "russpold"], ["normal", "normal"]],
                 form.dig("attributes", "bc_queue", "options")
    assert_equal 8, form.dig("attributes", "sh_cpus", "value")
    assert_equal 32, form.dig("attributes", "sh_mem", "value")
    assert_equal 8, form.dig("attributes", "bc_num_hours", "value")

    %w[herdr_session herdr_agents sh_workspace bc_queue sh_cpus sh_mem bc_num_hours].each do |field|
      assert_equal true, form.dig("attributes", field, "required"), "#{field} must be required"
    end
  end

  def test_submit_template_uses_basic_connection_and_resources
    submit = YAML.safe_load(render("sh_herdr/submit.yml.erb", sh_cpus: "12", sh_mem: "48"))
    assert_equal "basic", submit.dig("batch_connect", "template")
    assert_equal %w[herdr_session herdr_workspace], submit.dig("batch_connect", "conn_params")
    assert_equal ["-N", "1", "-c", "12", "--mem", "48G"], submit.dig("script", "native")
    refute_includes submit.dig("script", "native"), "-p"
    refute_includes submit.dig("script", "native"), "--partition"
    refute_includes submit.dig("script", "native"), "-t"
    refute_includes submit.dig("script", "native"), "--time"

    defaults = YAML.safe_load(render("sh_herdr/submit.yml.erb"))
    assert_equal ["-N", "1", "-c", "8", "--mem", "32G"], defaults.dig("script", "native")
  end

  def test_manifest_identifies_the_batch_connect_app
    manifest = YAML.safe_load(File.read(File.join(APP_ROOT, "sh_herdr/manifest.yml")))
    assert_equal "Herdr", manifest.fetch("name")
    assert_equal "Interactive Apps", manifest.fetch("category")
    assert_equal "Development", manifest.fetch("subcategory")
    assert_equal "batch_connect", manifest.fetch("role")
    assert_includes manifest.fetch("description"), "persistent agent workspace"
  end

  def test_form_has_only_supported_resource_choices
    form = YAML.safe_load(render("sh_herdr/form.yml.erb"))
    refute_includes form.fetch("form"), "sh_gpus"
    assert_equal({
      "label" => "Initial workspace",
      "help" => "Choose the directory used for Herdr's initial workspace.",
      "required" => true,
      "data-filepicker" => true,
      "data-target-file-type" => "dirs",
      "data-default-directory" => "$HOME",
      "readonly" => true,
      "value" => "$HOME"
    }, form.dig("attributes", "sh_workspace"))
    assert_includes form.dig("attributes", "sh_preexec", "label"), "Advanced"
    assert_includes form.dig("attributes", "sh_preexec", "help"), "execute as the user"
  end
end
