"use client";

import { useEffect, useRef, useState } from "react";
import { IncompleteJsonParser } from "incomplete-json-parser";
import { ChatOutput } from "@/types";

const TextArea = ({
  setIsGenerating,
  isGenerating,
  setOutputs,
  outputs,
}: {
  setIsGenerating: React.Dispatch<React.SetStateAction<boolean>>;
  isGenerating: boolean;
  setOutputs: React.Dispatch<React.SetStateAction<ChatOutput[]>>;
  outputs: ChatOutput[];
}) => {
  // Parser instance to handle incomplete JSON streaming responses
  const parser = new IncompleteJsonParser();

  const [text, setText] = useState("");
  const textAreaRef = useRef<HTMLTextAreaElement>(null);

  // Handles form submission
  async function submit(e: React.FormEvent) {
    e.preventDefault();
    sendMessage(text);
    setText("");
  }

  // Helper function to parse the stream buffer
  const parseStreamBuffer = (
    buffer: string
  ): { steps: { name: string; result: Record<string, string> }[]; answer: { answer: string; tools_used: string[] } } => {
    const steps: { name: string; result: Record<string, string> }[] = [];
    let answer = { answer: "", tools_used: [] as string[] };
    
    if (!buffer.includes("</step_name>")) {
      return { steps, answer };
    }

    // Parse tool steps (non-final_answer)
    const fullStepPattern = /<step><step_name>([^<]*)<\/step_name>([^<]*?)(?=<step>|<\/step>|$)/g;
    const matches = [...buffer.matchAll(fullStepPattern)];

    for (const match of matches) {
      const [, matchStepName, jsonStr] = match;
      if (matchStepName !== "final_answer" && jsonStr) {
        try {
          const result = JSON.parse(jsonStr);
          steps.push({ name: matchStepName, result });
        } catch {
          // JSON parse error, skip
        }
      }
    }
    
    // Check for final_answer
    const finalAnswerMatch = buffer.match(
      /<step><step_name>final_answer<\/step_name>([^<]*)/
    );
    if (finalAnswerMatch) {
      const [, jsonStr] = finalAnswerMatch;
      try {
        // Parse the JSON directly - it contains the full answer object
        answer = JSON.parse(jsonStr);
      } catch {
        // Try with incomplete parser for streaming data
        try {
          parser.write(jsonStr);
          const result = parser.getObjects();
          if (result) answer = result;
          parser.reset();
        } catch {
          // Incomplete JSON, will be parsed on next chunk
        }
      }
    }
    
    return { steps, answer };
  };

  // Sends message to the api and handles streaming response processing
  const sendMessage = async (text: string) => {
    const newOutputs = [
      ...outputs,
      {
        question: text,
        steps: [],
        result: {
          answer: "",
          tools_used: [],
        },
      },
    ];

    setOutputs(newOutputs);
    setIsGenerating(true);

    const apiUrl = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8000";
    console.log("API URL:", apiUrl);

    try {
      console.log("Sending request to:", `${apiUrl}/invoke?content=${encodeURIComponent(text)}`);
      const res = await fetch(`${apiUrl}/invoke?content=${encodeURIComponent(text)}`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
      });

      console.log("Response status:", res.status);
      if (!res.ok) {
        throw new Error(`Error: ${res.status}`);
      }

      // Use streaming reader for live updates
      let buffer = "";
      let answer = { answer: "", tools_used: [] as string[] };
      let currentSteps: { name: string; result: Record<string, string> }[] = [];
      
      const reader = res.body?.getReader();
      const decoder = new TextDecoder();
      
      if (reader) {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          
          buffer += decoder.decode(value, { stream: true });
          console.log("Stream chunk received, buffer length:", buffer.length);
          
          // Parse current buffer for live updates
          const parsedData = parseStreamBuffer(buffer);
          currentSteps = parsedData.steps;
          if (parsedData.answer.answer) {
            answer = parsedData.answer;
          }
          
          // Update output with current parsed content
          setOutputs((prevState) => {
            const lastOutput = prevState[prevState.length - 1];
            return [
              ...prevState.slice(0, -1),
              {
                ...lastOutput,
                steps: currentSteps,
                result: answer,
              },
            ];
          });
        }
      } else {
        // Fallback to text() if reader not available
        buffer = await res.text();
        const parsedData = parseStreamBuffer(buffer);
        currentSteps = parsedData.steps;
        answer = parsedData.answer;
        
        // Update output with parsed content
        setOutputs((prevState) => {
          const lastOutput = prevState[prevState.length - 1];
          return [
            ...prevState.slice(0, -1),
            {
              ...lastOutput,
              steps: currentSteps,
              result: answer,
            },
          ];
        });
      }
    } catch (error) {
      console.error(error);
    } finally {
      setIsGenerating(false);
    }
  };

  // Submit form when Enter is pressed (without Shift)
  function submitOnEnter(e: React.KeyboardEvent<HTMLTextAreaElement>) {
    if (e.code === "Enter" && !e.shiftKey) {
      submit(e);
    }
  }

  // Dynamically adjust textarea height based on content
  const adjustHeight = () => {
    const textArea = textAreaRef.current;
    if (textArea) {
      textArea.style.height = "auto";
      textArea.style.height = `${textArea.scrollHeight}px`;
    }
  };

  // Adjust height whenever text content changes
  useEffect(() => {
    adjustHeight();
  }, [text]);

  // Add resize event listener to adjust height on window resize
  useEffect(() => {
    const handleResize = () => adjustHeight();
    window.addEventListener("resize", handleResize);
    return () => window.removeEventListener("resize", handleResize);
  }, []);

  return (
    <form
      onSubmit={submit}
      className={`flex gap-3 z-10 ${
        outputs.length > 0 ? "fixed bottom-0 left-0 right-0 container pb-5" : ""
      }`}
    >
      <div className="w-full flex items-center bg-gray-800 rounded border border-gray-600">
        <textarea
          ref={textAreaRef}
          value={text}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => submitOnEnter(e)}
          rows={1}
          className="w-full p-3 bg-transparent min-h-20 focus:outline-none resize-none"
          placeholder="Ask a question..."
        />

        <button
          type="submit"
          disabled={isGenerating || !text}
          className="disabled:bg-gray-500 bg-[#09BDE1] transition-colors w-9 h-9 rounded-full shrink-0 flex items-center justify-center mr-2"
        >
          <ArrowIcon />
        </button>
      </div>
    </form>
  );
};

const ArrowIcon = () => (
  <svg
    xmlns="http://www.w3.org/2000/svg"
    width="16"
    height="16"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="2"
    strokeLinecap="round"
    strokeLinejoin="round"
    className="lucide lucide-arrow-right"
  >
    <path d="M5 12h14" />
    <path d="m12 5 7 7-7 7" />
  </svg>
);

export default TextArea;
