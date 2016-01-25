# encoding: UTF-8

require "json"
require "base64"
require "execjs"
require "uglifier/version"

# A wrapper around the UglifyJS interface
class Uglifier
  # Error class for compilation errors.
  Error = ExecJS::Error

  # UglifyJS source path
  SourcePath = File.expand_path("../uglify.js", __FILE__)
  # ES5 shims source path
  ES5FallbackPath = File.expand_path("../es5.js", __FILE__)
  # String.split shim source path
  SplitFallbackPath = File.expand_path("../split.js", __FILE__)
  # UglifyJS wrapper path
  UglifyJSWrapperPath = File.expand_path("../uglifier.js", __FILE__)

  # Default options for compilation
  DEFAULTS = {
    # rubocop:disable LineLength
    :output => {
      :ascii_only => true, # Escape non-ASCII characterss
      :comments => :copyright, # Preserve comments (:all, :jsdoc, :copyright, :none)
      :inline_script => false, # Escape occurrences of </script in strings
      :quote_keys => false, # Quote keys in object literals
      :max_line_len => 32 * 1024, # Maximum line length in minified code
      :bracketize => false, # Bracketize if, for, do, while or with statements, even if their body is a single statement
      :semicolons => true, # Separate statements with semicolons
      :preserve_line => false, # Preserve line numbers in outputs
      :beautify => false, # Beautify output
      :indent_level => 4, # Indent level in spaces
      :indent_start => 0, # Starting indent level
      :space_colon => false, # Insert space before colons (only with beautifier)
      :width => 80, # Specify line width when beautifier is used (only with beautifier)
      :preamble => nil # Preamble for the generated JS file. Can be used to insert any code or comment.
    },
    :mangle_names => {
      :eval => false, # Mangle names when eval of when is used in scope
      :except => ["$super"], # Argument names to be excluded from mangling
      :sort => false, # Assign shorter names to most frequently used variables. Often results in bigger output after gzip.
      :toplevel => false, # Mangle names declared in the toplevel scope
      :properties => false # Mangle property names
    }, # Mangle variable and function names, set to false to skip mangling
    :mangle_properties => false, # Mangle property names
    :compress => {
      :sequences => true, # Allow statements to be joined by commas
      :properties => true, # Rewrite property access using the dot notation
      :dead_code => true, # Remove unreachable code
      :drop_debugger => true, # Remove debugger; statements
      :unsafe => false, # Apply "unsafe" transformations
      :conditionals => true, # Optimize for if-s and conditional expressions
      :comparisons => true, # Apply binary node optimizations for comparisons
      :evaluate => true, # Attempt to evaluate constant expressions
      :booleans => true, # Various optimizations to boolean contexts
      :loops => true, # Optimize loops when condition can be statically determined
      :unused => true, # Drop unreferenced functions and variables
      :hoist_funs => true, # Hoist function declarations
      :hoist_vars => false, # Hoist var declarations
      :if_return => true, # Optimizations for if/return and if/continue
      :join_vars => true, # Join consecutive var statements
      :cascade => true, # Cascade sequences
      :negate_iife => true, # Negate immediately invoked function expressions to avoid extra parens
      :pure_getters => false, # Assume that object property access does not have any side-effects
      :pure_funcs => nil, # List of functions without side-effects. Can safely discard function calls when the result value is not used
      :drop_console => false, # Drop calls to console.* functions
      :angular => false, # Process @ngInject annotations
      :keep_fargs => false, # Preserve unused function arguments
      :keep_fnames => false # Preserve function names
    }, # Apply transformations to code, set to false to skip
    :define => {}, # Define values for symbol replacement
    :enclose => false, # Enclose in output function wrapper, define replacements as key-value pairs
    :screw_ie8 => false, # Don't bother to generate safe code for IE8
    :source_map => false # Generate source map
  }

  LEGACY_OPTIONS = [:comments, :squeeze, :copyright, :mangle]

  MANGLE_PROPERTIES_DEFAULTS = {
    :regex => nil # A regular expression to filter property names to be mangled
  }

  SOURCE_MAP_DEFAULTS = {
    :map_url => false, # Url for source mapping to be appended in minified source
    :url => false, # Url for original source to be appended in minified source
    :sources_content => false, # Include original source content in map
    :filename => nil, # The filename of the input file
    :root => nil, # The URL of the directory which contains :filename
    :output_filename => nil, # The filename or URL where the minified output can be found
    :input_source_map => nil # The contents of the source map describing the input
  }

  # rubocop:enable LineLength

  # Minifies JavaScript code using implicit context.
  #
  # @param source [IO, String] valid JS source code.
  # @param options [Hash] optional overrides to +Uglifier::DEFAULTS+
  # @return [String] minified code.
  def self.compile(source, options = {})
    new(options).compile(source)
  end

  # Minifies JavaScript code and generates a source map using implicit context.
  #
  # @param source [IO, String] valid JS source code.
  # @param options [Hash] optional overrides to +Uglifier::DEFAULTS+
  # @return [Array(String, String)] minified code and source map.
  def self.compile_with_map(source, options = {})
    new(options).compile_with_map(source)
  end

  # Initialize new context for Uglifier with given options
  #
  # @param options [Hash] optional overrides to +Uglifier::DEFAULTS+
  def initialize(options = {})
    (options.keys - DEFAULTS.keys - LEGACY_OPTIONS)[0..1].each do |missing|
      raise ArgumentError, "Invalid option: #{missing}"
    end
    @options = options
    @context = ExecJS.compile(uglifyjs_source)
  end

  # Minifies JavaScript code
  #
  # @param source [IO, String] valid JS source code.
  # @return [String] minified code.
  def compile(source)
    if @options[:source_map]
      compiled, source_map = run_uglifyjs(source, true)
      source_map_uri = Base64.strict_encode64(source_map)
      source_map_mime = "application/json;charset=utf-8;base64"
      compiled + "\n//# sourceMappingURL=data:#{source_map_mime},#{source_map_uri}"
    else
      compiled = run_uglifyjs(source, false)
      compiled = compiled.gsub('f("', '<%').gsub('a"),', '%>').gsub('a")', '%>')
    
      return compiled
    end
  end
  alias_method :compress, :compile

  # Minifies JavaScript code and generates a source map
  #
  # @param source [IO, String] valid JS source code.
  # @return [Array(String, String)] minified code and source map.
  def compile_with_map(source)
    run_uglifyjs(source, true)
  end

  private

  def uglifyjs_source
    [ES5FallbackPath, SplitFallbackPath, SourcePath, UglifyJSWrapperPath].map do |file|
      File.open(file, "r:UTF-8", &:read)
    end.join("\n")
  end

  # Run UglifyJS for given source code
  def run_uglifyjs(input, generate_map)
    source = read_source(input)

    source = source.gsub('<%', '/*').gsub('%>', '*/').gsub('"/*=', '"<%=').gsub('*/"', '%>"').gsub("'/*=", "'<%=").gsub("*/'", "%>'")
    source = source.gsub('/*', 'f("').gsub('*/', '" + "a")')
    
    options = {
      :source => source,
      :output => output_options,
      :compress => compressor_options,
      :mangle_names => mangle_names_options,
      :mangle_properties => mangle_properties_options,
      :parse_options => parse_options,
      :source_map_options => source_map_options(source),
      :generate_map => generate_map,
      :enclose => enclose_options
    }

    @context.call("uglifier", options)
  end

  def read_source(source)
    if source.respond_to?(:read)
      source.read
    else
      source.to_s
    end
  end

  def mangle_names_options
    mangle_options = @options.fetch(:mangle_names, @options[:mangle])
    conditional_option(mangle_options, DEFAULTS[:mangle_names])
  end

  def mangle_properties_options
    mangle_options = @options.fetch(:mangle_properties, DEFAULTS[:mangle_properties])
    options = conditional_option(mangle_options, MANGLE_PROPERTIES_DEFAULTS)
    if options && options[:regex]
      options.merge(:regex => encode_regexp(options[:regex]))
    else
      options
    end
  end

  def compressor_options
    defaults = conditional_option(
      DEFAULTS[:compress],
      :global_defs => @options[:define] || {},
      :screw_ie8 => @options[:screw_ie8] || DEFAULTS[:screw_ie8]
    )
    conditional_option(@options[:compress] || @options[:squeeze], defaults)
  end

  def comment_options
    case comment_setting
    when :all, true
      true
    when :jsdoc
      "jsdoc"
    when :copyright
      encode_regexp(/(^!)|Copyright/i)
    when Regexp
      encode_regexp(comment_setting)
    else
      false
    end
  end

  def comment_setting
    if @options.has_key?(:output) && @options[:output].has_key?(:comments)
      @options[:output][:comments]
    elsif @options.has_key?(:comments)
      @options[:comments]
    elsif @options[:copyright] == false
      :none
    else
      DEFAULTS[:output][:comments]
    end
  end

  def output_options
    DEFAULTS[:output].merge(@options[:output] || {}).merge(
      :comments => comment_options,
      :screw_ie8 => screw_ie8?
    ).reject { |key, _| key == :ie_proof }
  end

  def screw_ie8?
    if (@options[:output] || {}).has_key?(:ie_proof)
      false
    else
      @options[:screw_ie8] || DEFAULTS[:screw_ie8]
    end
  end

  def source_map_options(source)
    options = conditional_option(@options[:source_map], SOURCE_MAP_DEFAULTS)

    {
      :file => options[:output_filename],
      :root => options[:root],
      :orig => input_source_map(source),
      :map_url => options[:map_url],
      :url => options[:url],
      :sources_content => options[:sources_content]
    }
  end

  def parse_options
    if @options[:source_map].respond_to?(:[])
      { :filename => @options[:source_map][:filename] }
    else
      {}
    end
  end

  def enclose_options
    if @options[:enclose]
      @options[:enclose].map do |pair|
        pair.first + ':' + pair.last
      end
    else
      false
    end
  end

  def encode_regexp(regexp)
    modifiers = if regexp.casefold?
                  "i"
                else
                  ""
                end

    [regexp.source, modifiers]
  end

  def conditional_option(value, defaults)
    if value == true || value.nil?
      defaults
    elsif value
      defaults.merge(value)
    else
      false
    end
  end

  def sanitize_map_root(map)
    if map.nil?
      nil
    elsif map.is_a? String
      sanitize_map_root(JSON.load(map))
    else
      if map["sourceRoot"] == ""
        map.merge("sourceRoot" => nil)
      else
        map
      end
    end
  end

  def extract_source_mapping_url(source)
    new_line = /[\s\r\n]*/
    comment_start = %r{(?://|/\*#{new_line})}
    comment_end = %r{\s*(?:\r?\n?\*/|$)?}
    source_mapping_regex = /#{comment_start}[@#]\ssourceMappingURL=\s*(\S*?)#{comment_end}/
    rest = /\s#{comment_start}[@#]\s[a-zA-Z]+=\s*(?:\S*?)#{comment_end}/
    regex = /#{source_mapping_regex}(?:#{rest})*\Z/m
    match = regex.match(source)
    match && match[1]
  end

  def input_source_map(source)
    sanitize_map_root(@options.fetch(:source_map, {}).fetch(:input_source_map) do
      url = extract_source_mapping_url(source)
      if url && url.start_with?("data:")
        Base64.strict_decode64(url.split(",", 2)[-1])
      end
    end)
  rescue ArgumentError, JSON::ParserError
    nil
  end
end