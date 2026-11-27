defmodule TypstyExamples.Samples do
  @moduledoc """
  Sample data for each example, the way an application would load it from its database
  before rendering a document.
  """

  alias TypstyExamples.Customer

  @doc "The company every example comes from."
  def company do
    %{
      name: "Kestrel Labs",
      address: ["410 Alder Street, Suite 300", "Portland, OR 97204"],
      email: "billing@kestrel.example",
      website: "kestrel.example"
    }
  end

  @doc "Assigns for `TypstyExamples.Invoice`."
  def invoice do
    %{
      company: company(),
      customer: %Customer{
        id: 381,
        name: "Fernwood Outfitters",
        contact: "Dana Whitfield",
        email: "accounts@fernwood.example",
        address: ["1200 Market Avenue", "Denver, CO 80202"],
        billing_id: "cus_internal_7731"
      },
      number: "INV-2026-0142",
      status: :open,
      issued_on: ~D[2026-11-02],
      due_on: ~D[2026-12-02],
      purchase_order: "PO-55810",
      lines: [
        %{
          description: "Kestrel Analytics, Team plan",
          details: "November 1 – November 30, 2026 · 25 seats",
          quantity: 25,
          unit_price: Decimal.new("39.00")
        },
        %{
          description: "Additional event volume",
          details: "1.2M events over the plan's 5M, per 100k",
          quantity: 12,
          unit_price: Decimal.new("4.50")
        },
        %{
          description: "Data warehouse sync",
          details: "Snowflake connector",
          quantity: 1,
          unit_price: Decimal.new("149.00")
        },
        %{
          description: "Onboarding workshop",
          details: "Two remote sessions for the analytics team",
          quantity: 2,
          unit_price: Decimal.new("450.00")
        },
        %{description: "Priority support", quantity: 1, unit_price: Decimal.new("199.00")}
      ],
      discount: %{label: "Annual commitment (10%)", amount: Decimal.new("227.70")},
      tax_rate: Decimal.new("0.0825"),
      amount_paid: Decimal.new("0.00"),
      payment_url: "https://pay.kestrel.example/i/INV-2026-0142",
      notes:
        "Thank you for your business. Payment is due within 30 days. Questions about this invoice? Write to billing@kestrel.example."
    }
  end

  @months ~w(Oct Nov Dec Jan Feb Mar Apr May Jun Jul Aug Sep)

  @doc "Assigns for `TypstyExamples.Report`."
  def report do
    revenue = [612, 618, 641, 655, 662, 690, 704, 721, 748, 776, 801, 833]

    accounts = %{
      "Starter" => [521, 530, 534, 549, 556, 561, 570, 577, 589, 594, 603, 610],
      "Team" => [382, 389, 395, 404, 411, 420, 428, 437, 445, 452, 463, 470],
      "Enterprise" => [141, 146, 150, 157, 163, 168, 174, 181, 186, 193, 199, 204]
    }

    plans = ["Starter", "Team", "Enterprise"]

    %{
      company: company(),
      title: "Quarterly Business Review",
      period: "Q3 2026",
      prepared_for: "Board of Directors",
      prepared_by: "Finance & Analytics",
      published_on: ~D[2026-10-15],
      kpis: [
        %{label: "Revenue", value: "$2.41M", change: 0.124},
        %{label: "Net retention", value: "118%", change: 0.031},
        %{label: "Active accounts", value: "1,284", change: 0.087},
        %{label: "Gross margin", value: "78.2%", change: -0.011}
      ],
      monthly_revenue: Enum.zip_with(@months, revenue, &%{month: &1, revenue: &2 * 1000}),
      plans: plans,
      accounts:
        for {month, index} <- Enum.with_index(@months), plan <- plans do
          %{month: month, plan: plan, accounts: Enum.at(accounts[plan], index)}
        end,
      regions: [
        %{region: "North America", revenue: 1_180_000, growth: 0.11},
        %{region: "Europe", revenue: 640_000, growth: 0.16},
        %{region: "Asia Pacific", revenue: 390_000, growth: 0.21},
        %{region: "Latin America", revenue: 200_000, growth: -0.04}
      ]
    }
  end

  @doc "Assigns for `TypstyExamples.CheatSheet`: a cheat sheet for Typsty."
  def cheat_sheet do
    %{
      title: "Typsty",
      subtitle: "Typst documents from Elixir",
      version: "0.1",
      url: "hexdocs.pm/typsty",
      sections: [
        %{
          title: "Documents",
          entries: [
            %{
              note: "A document module defines render/1 with the ~TYPST sigil:",
              lang: "elixir",
              code: """
              defmodule MyApp.Invoice do
                use Typsty

                def render(assigns) do
                  ~TYPST\"""
                  = Invoice #assigns.number
                  \"""
                end
              end\
              """
            },
            %{
              note:
                "Or it leaves render/1 out, and its template is in a .typ file next to it: invoice.ex and invoice.typ.",
              lang: "elixir",
              code: "defmodule MyApp.Invoice do\n  use Typsty\nend"
            },
            %{note: "Templates are checked when they compile: a syntax error fails the build."}
          ]
        },
        %{
          title: "Rendering",
          entries: [
            %{
              note: "A PDF, a PNG for each page, or an SVG for each page:",
              lang: "elixir",
              code: """
              {:ok, pdf} = Invoice.to_pdf(assigns)
              {:ok, pngs} = Invoice.to_png(assigns, ppi: 300)
              {:ok, svgs} = Invoice.to_svg(assigns)
              pdf = Invoice.to_pdf!(assigns)\
              """
            },
            %{
              note: "Templates that aren't in a module, such as ones stored in a database:",
              lang: "elixir",
              code: """
              Typsty.to_pdf("Hi #assigns.name", %{name: "Ada"})
              Typsty.validate(source)\
              """
            }
          ]
        },
        %{
          title: "Configuration",
          entries: [
            %{
              note: "Defaults for every render, in config/runtime.exs:",
              lang: "elixir",
              code: """
              config :typsty,
                system_fonts: false,
                font_paths: [
                  Application.app_dir(:my_app, "priv/fonts")
                ],
                pool: MyApp.TypstPool\
              """
            },
            %{
              note: "Format sigils and .typ files with mix format, in .formatter.exs:",
              lang: "elixir",
              code: """
              [
                plugins: [Typsty.Formatter],
                inputs: ["{lib,test}/**/*.{ex,exs,typ}"]
              ]\
              """
            }
          ]
        },
        %{
          title: "Assigns",
          entries: [
            %{
              note: "Templates read them from the assigns dictionary:",
              lang: "typ",
              code: "Billed to #assigns.customer.name\n#for item in assigns.items [- #item.name]"
            },
            %{
              note: "Optional ones, with a default:",
              lang: "typ",
              code: ~S|#let notes = assigns.at("notes", default: none)|
            },
            %{
              note:
                "Maps become dictionaries, lists arrays, atoms strings, and Date, DateTime and Decimal datetimes and decimals. Other structs need Typsty.Encoder:",
              lang: "elixir",
              code: "@derive {Typsty.Encoder, only: [:name, :email]}\ndefstruct [:name, :email, :password_hash]"
            }
          ]
        },
        %{
          title: "Components",
          entries: [
            %{
              note: "Typst functions to share between documents: tables, headers, footers.",
              lang: "elixir",
              code: """
              defmodule MyApp.Tables do
                use Typsty.Component
                # Its source is in tables.typ, or render/0
              end\
              """
            },
            %{
              note: "A document lists them, and imports them from components/:",
              lang: "elixir",
              code: "use Typsty, components: [MyApp.Tables]"
            },
            %{lang: "typ", code: ~S|#import "components/tables.typ": line-items|},
            %{
              note:
                "They may only define things (#let and #import), and get data as arguments: they can't read sys.inputs."
            }
          ]
        },
        %{
          title: "Files",
          entries: [
            %{
              note: "Images and data are passed in memory, and never written to disk:",
              lang: "elixir",
              code: ~S"""
              files = %{"logo.png" => File.read!(path)}
              Report.to_pdf(assigns, files: files)
              """
            },
            %{lang: "typ", code: ~S|#image("logo.png", width: 3cm)|},
            %{
              note:
                "Name them yourself, never with names users give. A component's own files go in a folder next to it."
            }
          ]
        },
        %{
          title: "Packages",
          entries: [
            %{
              note: "Download them into priv/typst/packages, with the packages they import:",
              lang: "shell",
              code: "mix typsty.packages.get @preview/cetz:0.4.2"
            },
            %{
              note: "And point the :package_paths option at that directory. Renders never download them.",
              lang: "elixir",
              code: ~S"""
              config :typsty,
                package_paths: [
                  Application.app_dir(:my_app, "priv/typst/packages")
                ]
              """
            }
          ]
        },
        %{
          title: "Separate processes",
          entries: [
            %{
              note: "For input from users that isn't well validated, render in a pool of OS processes:",
              lang: "elixir",
              code: """
              children = [
                {Typsty.Pool,
                 name: MyApp.TypstPool, size: 4,
                 memory_limit: 1_000_000_000}
              ]

              Invoice.to_pdf(assigns, pool: MyApp.TypstPool)\
              """
            },
            %{note: "A render past its timeout or memory limit is stopped at once, and its worker replaced."}
          ]
        },
        %{
          title: "Errors",
          entries: [
            %{
              note: "Errors that depend on the data are returned, and point at the line in the template:",
              lang: "elixir",
              code: """
              case Invoice.to_pdf(assigns) do
                {:ok, pdf} -> send_pdf(conn, pdf)
                {:error, %{reason: :busy}} -> retry_later(conn)
                {:error, error} -> raise error
              end\
              """
            },
            %{note: "Invalid options raise an ArgumentError that names the option."}
          ]
        }
      ]
    }
  end

  @doc "Assigns for `TypstyExamples.Statement`."
  def statement do
    transactions =
      [
        {1, "Rent, Alder Street office", "Rent", "-6200.00"},
        {1, "Payment from Fernwood Outfitters", "Customers", "2218.37"},
        {2, "Amazon Web Services", "Software", "-1843.12"},
        {3, "Payment from Halcyon Health", "Customers", "8400.00"},
        {3, "Figma", "Software", "-225.00"},
        {6, "Delta Air Lines", "Travel", "-684.40"},
        {6, "Marriott Seattle", "Travel", "-912.75"},
        {7, "Payment from Brightline Media", "Customers", "3150.00"},
        {8, "Staples", "Office", "-142.18"},
        {9, "Lunch with Halcyon Health", "Meals", "-186.50"},
        {10, "Payment from Orchard Grocers", "Customers", "5600.00"},
        {13, "Google Workspace", "Software", "-336.00"},
        {14, "Portland General Electric", "Utilities", "-418.22"},
        {15, "Payroll", "Payroll", "-28450.00"},
        {15, "Payment from Northgate Logistics", "Customers", "12750.00"},
        {16, "Comcast Business", "Utilities", "-249.99"},
        {17, "Payment from Fernwood Outfitters", "Customers", "975.00"},
        {20, "GitHub", "Software", "-441.00"},
        {20, "Coffee for the team", "Meals", "-64.80"},
        {21, "Payment from Pinecrest Schools", "Customers", "4200.00"},
        {22, "Alaska Airlines", "Travel", "-398.60"},
        {22, "Hyatt San Francisco", "Travel", "-1104.30"},
        {23, "Team dinner", "Meals", "-612.40"},
        {24, "Payment from Halcyon Health", "Customers", "8400.00"},
        {27, "Office chairs", "Office", "-1289.00"},
        {28, "Slack", "Software", "-287.50"},
        {29, "Payment from Riverbend Credit Union", "Customers", "9800.00"},
        {30, "Liability insurance", "Insurance", "-740.00"},
        {31, "Payroll", "Payroll", "-28450.00"},
        {31, "Payment from Brightline Media", "Customers", "3150.00"},
        {31, "Interest", "Interest", "18.42"}
      ]
      |> Enum.map(fn {day, description, category, amount} ->
        %{date: Date.new!(2026, 10, day), description: description, category: category, amount: Decimal.new(amount)}
      end)

    %{
      company: company(),
      account: %{
        holder: "Kestrel Labs, Inc.",
        address: ["410 Alder Street, Suite 300", "Portland, OR 97204"],
        name: "Business checking",
        last4: "4821"
      },
      starts_on: ~D[2026-10-01],
      ends_on: ~D[2026-10-31],
      opening_balance: Decimal.new("48213.07"),
      transactions: transactions
    }
  end

  @doc "Assigns for `TypstyExamples.Tickets`."
  def tickets do
    %{
      event: %{
        name: "Kestrel Summit 2027",
        tagline: "A day on analytics, for teams that ship",
        venue: "Riverside Hall",
        address: "120 Water Avenue, Portland, OR",
        starts_at: ~N[2027-03-18 09:00:00],
        ends_at: ~N[2027-03-18 17:30:00]
      },
      order: %{number: "KS-20418", email: "dana@fernwood.example"},
      tickets: [
        %{holder: "Dana Whitfield", type: "Full pass", admits: "Talks and workshops", code: "KS27-8F3K-2Q9D"},
        %{holder: "Marcus Oyelaran", type: "Conference", admits: "Talks", code: "KS27-4T7M-9XWB"},
        %{holder: "Priya Raman", type: "Conference", admits: "Talks", code: "KS27-6HC2-J5RE"}
      ]
    }
  end

  @doc "Assigns for `TypstyExamples.ShippingLabel`."
  def shipping_label do
    %{
      from: %{name: "Kestrel Labs Store", address: ["410 Alder Street, Suite 300", "Portland, OR 97204"]},
      to: %{name: "Dana Whitfield", address: ["Fernwood Outfitters", "1200 Market Avenue", "Denver, CO 80202"]},
      carrier: "SWIFTPOST",
      service: "GROUND",
      order: "KS-20418",
      shipped_on: ~D[2026-11-24],
      packages: [
        %{tracking: "SP4827993011840", weight: 3.2, routing: "CO 802 4-10", reference: "KS-20418-1"},
        %{tracking: "SP4827993011857", weight: 1.4, routing: "CO 802 4-10", reference: "KS-20418-2"}
      ]
    }
  end

  @doc "Assigns for `TypstyExamples.Certificate`."
  def certificate do
    %{
      recipient: "Priya Raman",
      course: "Product Analytics Foundations",
      hours: 12,
      completed_on: ~D[2026-11-19],
      instructor: %{name: "Elena Marquez", title: "Lead Instructor, Kestrel Academy"},
      id: "KA-2026-11-0457"
    }
  end

  @doc """
  The files `TypstyExamples.Certificate` renders with: the instructor's signature, which
  an application would load from wherever it keeps them.
  """
  def certificate_files do
    %{"signature.svg" => File.read!(Application.app_dir(:typsty_examples, "priv/samples/signature.svg"))}
  end
end
