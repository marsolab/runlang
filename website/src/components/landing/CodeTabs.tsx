import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";

const examples = [
  {
    id: "concurrency",
    label: "Concurrency",
    filename: "server.run",
    code: [
      { text: "package main", type: "keyword" },
      { text: "" },
      { text: 'use "fmt"', type: "string" },
      { text: 'use "time"', type: "string" },
      { text: "" },
      { text: "fun ", type: "keyword" },
      { text: "say", type: "fn" },
      { text: "(msg: ", type: "default" },
      { text: "string", type: "type" },
      { text: ") {", type: "default" },
      { text: "    for i in 0..3 {", type: "default" },
      { text: "        time.sleep(100)", type: "default" },
      { text: "        fmt.println(msg)", type: "default" },
      { text: "    }", type: "default" },
      { text: "}", type: "default" },
      { text: "" },
      { text: "pub fun ", type: "keyword" },
      { text: "main", type: "fn" },
      { text: "() {", type: "default" },
      { text: "    run ", type: "keyword" },
      { text: 'say("hello")', type: "default" },
      { text: '    say("world")', type: "default" },
      { text: "}", type: "default" },
    ],
  },
  {
    id: "errors",
    label: "Error Handling",
    filename: "config.run",
    code: [
      { text: "fun ", type: "keyword" },
      { text: "load_config", type: "fn" },
      { text: "(path: ", type: "default" },
      { text: "string", type: "type" },
      { text: ") ", type: "default" },
      { text: "!Config", type: "error" },
      { text: " {", type: "default" },
      { text: "    content := ", type: "default" },
      { text: "try ", type: "keyword" },
      { text: "read_file(path) ", type: "default" },
      { text: ':: "reading config"', type: "context" },
      { text: "    config := ", type: "default" },
      { text: "try ", type: "keyword" },
      { text: "parse(content) ", type: "default" },
      { text: ':: "parsing config"', type: "context" },
      { text: "    return config", type: "keyword" },
      { text: "}", type: "default" },
      { text: "" },
      { text: "pub fun ", type: "keyword" },
      { text: "main", type: "fn" },
      { text: "() ", type: "default" },
      { text: "!void", type: "error" },
      { text: " {", type: "default" },
      { text: "    switch ", type: "keyword" },
      { text: 'load_config("app.toml") {', type: "default" },
      { text: "        .ok(cfg) :: run_app(cfg),", type: "default" },
      { text: "        .err(e) :: fmt.println(e),", type: "default" },
      { text: "    }", type: "default" },
      { text: "}", type: "default" },
    ],
  },
  {
    id: "sumtypes",
    label: "Sum Types",
    filename: "state.run",
    code: [
      { text: "type ", type: "keyword" },
      { text: "State", type: "type" },
      { text: " = .loading | .ready(Data) | .error(", type: "default" },
      { text: "string", type: "type" },
      { text: ")", type: "default" },
      { text: "" },
      { text: "fun ", type: "keyword" },
      { text: "render", type: "fn" },
      { text: "(state: ", type: "default" },
      { text: "State", type: "type" },
      { text: ") {", type: "default" },
      { text: "    switch ", type: "keyword" },
      { text: "state {", type: "default" },
      { text: "        .loading :: show_spinner(),", type: "default" },
      { text: "        .ready(data) :: show_page(data),", type: "default" },
      { text: "        .error(msg) :: show_error(msg),", type: "default" },
      { text: "    }", type: "default" },
      { text: "}", type: "default" },
    ],
  },
  {
    id: "channels",
    label: "Channels",
    filename: "pipeline.run",
    code: [
      { text: "package main", type: "keyword" },
      { text: "" },
      { text: 'use "fmt"', type: "string" },
      { text: "" },
      { text: "fun ", type: "keyword" },
      { text: "producer", type: "fn" },
      { text: "(ch: ", type: "default" },
      { text: "chan[int]", type: "type" },
      { text: ") {", type: "default" },
      { text: "    for i in 0..5 {", type: "default" },
      { text: "        ch <- i", type: "default" },
      { text: "    }", type: "default" },
      { text: "}", type: "default" },
      { text: "" },
      { text: "pub fun ", type: "keyword" },
      { text: "main", type: "fn" },
      { text: "() {", type: "default" },
      { text: "    ch := ", type: "default" },
      { text: "alloc", type: "keyword" },
      { text: "(chan[int], 10)", type: "type" },
      { text: "" },
      { text: "    run ", type: "keyword" },
      { text: "producer(ch)", type: "default" },
      { text: "" },
      { text: "    for val in ch {", type: "default" },
      { text: "        fmt.println(val)", type: "default" },
      { text: "    }", type: "default" },
      { text: "}", type: "default" },
    ],
  },
];

const colorMap: Record<string, string> = {
  keyword: "text-blue-400",
  type: "text-green-400",
  fn: "text-white font-medium",
  string: "text-green-300",
  error: "text-red-400",
  context: "text-gray-500",
  default: "text-gray-300",
};

function renderCode(code: { text: string; type?: string }[]) {
  // Group consecutive items into lines
  const lines: { text: string; type?: string }[][] = [];
  let currentLine: { text: string; type?: string }[] = [];

  for (const item of code) {
    if (item.text === "" && currentLine.length === 0) {
      lines.push([{ text: "", type: "default" }]);
    } else if (
      item.text.startsWith("    ") ||
      item.text.startsWith("package") ||
      item.text.startsWith("use") ||
      item.text.startsWith("fun") ||
      item.text.startsWith("pub") ||
      item.text.startsWith("type") ||
      item.text.startsWith("}") ||
      item.text === ""
    ) {
      if (currentLine.length > 0) {
        lines.push(currentLine);
      }
      currentLine = [item];
      if (item.text === "" || item.text.endsWith("}") || item.text.endsWith("{") || item.text.endsWith(",") || item.text.endsWith(")")) {
        lines.push(currentLine);
        currentLine = [];
      }
    } else {
      currentLine.push(item);
    }
  }
  if (currentLine.length > 0) {
    lines.push(currentLine);
  }

  return lines.map((line, i) => (
    <div key={i} className="leading-relaxed">
      {line.map((segment, j) => (
        <span key={j} className={colorMap[segment.type || "default"]}>
          {segment.text}
        </span>
      ))}
    </div>
  ));
}

export default function CodeTabs() {
  return (
    <Tabs defaultValue="concurrency" className="w-full">
      <TabsList className="flex-wrap">
        {examples.map((ex) => (
          <TabsTrigger key={ex.id} value={ex.id}>
            {ex.label}
          </TabsTrigger>
        ))}
      </TabsList>
      {examples.map((ex) => (
        <TabsContent key={ex.id} value={ex.id}>
          <div className="rounded-xl border border-white/10 bg-run-code-bg shadow-2xl">
            <div className="flex items-center gap-2 border-b border-white/10 px-4 py-3">
              <span className="h-3 w-3 rounded-full bg-red-500/70"></span>
              <span className="h-3 w-3 rounded-full bg-yellow-500/70"></span>
              <span className="h-3 w-3 rounded-full bg-green-500/70"></span>
              <span className="ml-3 text-xs text-gray-500">{ex.filename}</span>
            </div>
            <pre className="overflow-x-auto p-6 font-mono text-sm">
              <code>{renderCode(ex.code)}</code>
            </pre>
          </div>
        </TabsContent>
      ))}
    </Tabs>
  );
}
