import type { ReactNode } from "react";

/**
 * The terminal's panel shell.
 *
 * `kind` is not decoration — it is the one piece of information the layout
 * encodes on its own. A READ panel reports what the chain says; an ACT panel
 * is somewhere you can spend money. They sit on surfaces of matched lightness
 * but opposing hue, so the grouping reads without implying that one is more
 * important than the other, and the chip colour repeats the signal for anyone
 * watching on a projector that flattens the fills.
 */
export const Panel = ({
  kind,
  code,
  title,
  note,
  hint,
  className = "",
  children,
}: {
  kind: "read" | "act";
  /** Three-letter role code shown in the chip. Encodes function, not sequence. */
  code: string;
  title: string;
  note?: ReactNode;
  /**
   * One line saying what this panel shows and why it matters. Three-letter
   * codes are efficient once you know the system and opaque before that, so
   * every panel carries its own plain-English gloss rather than relying on the
   * reader to have followed the briefing.
   */
  hint?: ReactNode;
  className?: string;
  children: ReactNode;
}) => (
  <section className={`jl-panel ${kind === "read" ? "jl-read" : "jl-act"} ${className}`}>
    <span className="jl-brk" aria-hidden="true" />
    <div className="jl-head">
      <span className="jl-code">{code}</span>
      <h2 className="jl-title" style={{ margin: 0 }}>
        {title}
      </h2>
      {note ? <span className="jl-note">{note}</span> : null}
    </div>
    {hint ? (
      <p className="jl-prose" style={{ margin: "-6px 0 16px", fontSize: 14 }}>
        {hint}
      </p>
    ) : null}
    {children}
  </section>
);
