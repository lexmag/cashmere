defmodule Cashmere.MixProject do
  use Mix.Project

  @source_url "https://github.com/lexmag/cashmere"
  @version "0.1.0"

  def project() do
    [
      app: :cashmere,
      version: @version,
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      description: description(),
      deps: deps(),
      package: package(),
      name: "Cashmere",
      docs: [
        main: "Cashmere",
        source_ref: "v#{@version}",
        source_url: @source_url
      ]
    ]
  end

  def application(), do: []

  defp description() do
    "High performance in-memory caching solution."
  end

  defp deps() do
    [{:ex_doc, "~> 0.24", only: :dev, runtime: false}]
  end

  defp package() do
    [
      maintainers: ["Aleksei Magusev"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
