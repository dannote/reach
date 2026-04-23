import Config

if Code.ensure_loaded?(Volt) do
  config :volt,
    define: %{"process.env.NODE_ENV" => ~s("production")},
    aliases: %{"@reach" => "assets/js"}
end
