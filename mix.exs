defmodule Cashmere.MixProject do
  use Mix.Project

  def project() do
    [
      app: :cashmere,
      version: "0.1.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      description: description(),
      deps: deps()
    ]
  end

  def application() do
    [
      extra_applications: [:logger]
    ]
  end

  defp description() do
    "High performance in-memory caching solution."
  end

  defp deps() do
    [{:ex_doc, ">= 0.0.0", only: :dev}]
  end
end
