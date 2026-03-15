import { useState, useEffect, useRef, useCallback } from "react";

const DEFAULT_CODE = `package main

pub fun main() {
    let message = "Hello, Run!"
    println(message)

    for i in 0..5 {
        println(i)
    }
}
`;

type Tab = "check" | "tokens" | "ast" | "format";

interface CheckResult {
	ok: boolean;
	errors: { line: number; col: number; message: string }[];
	nodeCount: number;
}

interface TokenEntry {
	tag: string;
	text: string;
	line: number;
	col: number;
}

interface AstNode {
	index: number;
	tag: string;
	token: string;
	lhs: number;
	rhs: number;
}

interface FormatResult {
	ok: boolean;
	result: string;
}

interface WasmExports {
	memory: WebAssembly.Memory;
	alloc: (len: number) => number;
	dealloc: (ptr: number, len: number) => void;
	getResultPtr: () => number;
	getResultLen: () => number;
	check: (ptr: number, len: number) => void;
	tokenize: (ptr: number, len: number) => void;
	parse: (ptr: number, len: number) => void;
	format: (ptr: number, len: number) => void;
}

function useCompiler() {
	const wasmRef = useRef<WasmExports | null>(null);
	const [ready, setReady] = useState(false);
	const [error, setError] = useState<string | null>(null);

	useEffect(() => {
		let cancelled = false;
		(async () => {
			try {
				const response = await fetch("/run-playground.wasm");
				const bytes = await response.arrayBuffer();
				const { instance } = await WebAssembly.instantiate(bytes, {
					env: {},
				});
				if (cancelled) return;
				wasmRef.current = instance.exports as unknown as WasmExports;
				setReady(true);
			} catch (e) {
				if (!cancelled)
					setError(e instanceof Error ? e.message : "Failed to load WASM");
			}
		})();
		return () => {
			cancelled = true;
		};
	}, []);

	const callWasm = useCallback(
		(fn: keyof Pick<WasmExports, "check" | "tokenize" | "parse" | "format">, source: string): string | null => {
			const wasm = wasmRef.current;
			if (!wasm) return null;

			const encoder = new TextEncoder();
			const encoded = encoder.encode(source);

			const ptr = wasm.alloc(encoded.length);
			if (ptr === 0) return null;

			const mem = new Uint8Array(wasm.memory.buffer);
			mem.set(encoded, ptr);

			wasm[fn](ptr, encoded.length);

			wasm.dealloc(ptr, encoded.length);

			const resultPtr = wasm.getResultPtr();
			const resultLen = wasm.getResultLen();

			const resultMem = new Uint8Array(wasm.memory.buffer);
			const resultBytes = resultMem.slice(resultPtr, resultPtr + resultLen);
			return new TextDecoder().decode(resultBytes);
		},
		[],
	);

	return { ready, error, callWasm };
}

function TabButton({
	label,
	active,
	onClick,
}: { label: string; active: boolean; onClick: () => void }) {
	return (
		<button
			type="button"
			onClick={onClick}
			className={`px-4 py-2 text-sm font-medium transition-colors ${
				active
					? "border-b-2 border-blue-500 text-blue-400"
					: "text-gray-400 hover:text-gray-200"
			}`}
		>
			{label}
		</button>
	);
}

function formatTokens(data: TokenEntry[]): string {
	const lines: string[] = [];
	for (const tok of data) {
		if (tok.tag === "eof") break;
		const tag = tok.tag.padEnd(22);
		const loc = `${tok.line}:${tok.col}`.padEnd(8);
		lines.push(`${loc} ${tag} ${tok.text}`);
	}
	return lines.join("\n");
}

function formatAst(data: AstNode[]): string {
	const lines: string[] = [];
	for (const node of data) {
		const idx = String(node.index).padStart(4);
		const tag = node.tag.padEnd(22);
		const token = node.token ? ` "${node.token}"` : "";
		lines.push(`[${idx}] ${tag} lhs=${node.lhs} rhs=${node.rhs}${token}`);
	}
	return lines.join("\n");
}

export default function Playground() {
	const [code, setCode] = useState(DEFAULT_CODE);
	const [activeTab, setActiveTab] = useState<Tab>("check");
	const [output, setOutput] = useState<string>("");
	const [isError, setIsError] = useState(false);
	const { ready, error: wasmError, callWasm } = useCompiler();
	const textareaRef = useRef<HTMLTextAreaElement>(null);

	const runAction = useCallback(
		(tab: Tab, source: string) => {
			if (!ready) return;

			const raw = callWasm(tab === "check" ? "check" : tab === "tokens" ? "tokenize" : tab === "ast" ? "parse" : "format", source);

			if (!raw) {
				setOutput("Error: WASM call failed");
				setIsError(true);
				return;
			}

			try {
				if (tab === "check") {
					const result: CheckResult = JSON.parse(raw);
					if (result.ok) {
						setOutput(`OK — ${result.nodeCount} AST nodes, no errors.`);
						setIsError(false);
					} else {
						const msgs = result.errors
							.map((e) => `  line ${e.line}, col ${e.col}: ${e.message}`)
							.join("\n");
						setOutput(`${result.errors.length} error(s):\n${msgs}`);
						setIsError(true);
					}
				} else if (tab === "tokens") {
					const tokens: TokenEntry[] = JSON.parse(raw);
					setOutput(formatTokens(tokens));
					setIsError(false);
				} else if (tab === "ast") {
					const nodes: AstNode[] = JSON.parse(raw);
					setOutput(formatAst(nodes));
					setIsError(false);
				} else if (tab === "format") {
					const result: FormatResult = JSON.parse(raw);
					if (result.ok) {
						setCode(result.result);
						setOutput("Code formatted.");
						setIsError(false);
					} else {
						setOutput(`Format error: ${result.result}`);
						setIsError(true);
					}
				}
			} catch {
				setOutput(`Parse error in result: ${raw}`);
				setIsError(true);
			}
		},
		[ready, callWasm],
	);

	useEffect(() => {
		if (ready) {
			runAction(activeTab, code);
		}
	}, [ready]);

	const handleRun = () => {
		runAction(activeTab, code);
	};

	const handleTabChange = (tab: Tab) => {
		setActiveTab(tab);
		runAction(tab, code);
	};

	const handleKeyDown = (e: React.KeyboardEvent) => {
		if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
			e.preventDefault();
			handleRun();
		}
		if (e.key === "Tab") {
			e.preventDefault();
			const textarea = textareaRef.current;
			if (!textarea) return;
			const start = textarea.selectionStart;
			const end = textarea.selectionEnd;
			const value = textarea.value;
			const newValue = `${value.substring(0, start)}    ${value.substring(end)}`;
			setCode(newValue);
			requestAnimationFrame(() => {
				textarea.selectionStart = start + 4;
				textarea.selectionEnd = start + 4;
			});
		}
	};

	if (wasmError) {
		return (
			<div className="flex h-full items-center justify-center text-red-400">
				<p>Failed to load compiler: {wasmError}</p>
			</div>
		);
	}

	return (
		<div className="flex h-full flex-col">
			{/* Toolbar */}
			<div className="flex items-center justify-between border-b border-white/10 bg-run-code-bg px-4 py-2">
				<div className="flex gap-1">
					<TabButton label="Check" active={activeTab === "check"} onClick={() => handleTabChange("check")} />
					<TabButton label="Tokens" active={activeTab === "tokens"} onClick={() => handleTabChange("tokens")} />
					<TabButton label="AST" active={activeTab === "ast"} onClick={() => handleTabChange("ast")} />
					<TabButton label="Format" active={activeTab === "format"} onClick={() => handleTabChange("format")} />
				</div>
				<div className="flex items-center gap-3">
					{!ready && (
						<span className="text-xs text-gray-500">Loading compiler...</span>
					)}
					<button
						type="button"
						onClick={handleRun}
						disabled={!ready}
						className="rounded bg-blue-600 px-4 py-1.5 text-sm font-medium text-white transition-colors hover:bg-blue-500 disabled:opacity-50"
					>
						Run
						<span className="ml-1.5 text-xs text-blue-200">{navigator.platform?.includes("Mac") ? "\u2318" : "Ctrl"}+\u23CE</span>
					</button>
				</div>
			</div>

			{/* Editor + Output */}
			<div className="grid flex-1 grid-cols-1 md:grid-cols-2">
				{/* Editor pane */}
				<div className="relative border-r border-white/10">
					<div className="absolute left-0 top-0 px-4 py-2 text-xs text-gray-500">
						source.run
					</div>
					<textarea
						ref={textareaRef}
						value={code}
						onChange={(e) => setCode(e.target.value)}
						onKeyDown={handleKeyDown}
						spellCheck={false}
						className="h-full w-full resize-none bg-transparent p-4 pt-8 font-mono text-sm leading-relaxed text-gray-100 outline-none placeholder:text-gray-600"
						placeholder="Write Run code here..."
					/>
				</div>

				{/* Output pane */}
				<div className="relative overflow-auto bg-run-dark">
					<div className="absolute left-0 top-0 px-4 py-2 text-xs text-gray-500">
						output
					</div>
					<pre
						className={`h-full overflow-auto p-4 pt-8 font-mono text-sm leading-relaxed ${
							isError ? "text-red-400" : "text-green-400"
						}`}
					>
						{output}
					</pre>
				</div>
			</div>
		</div>
	);
}
