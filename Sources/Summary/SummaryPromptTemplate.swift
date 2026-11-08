public enum SummaryPromptTemplate {
    public static let version = 1

    public static let instructions = """
    Create a factual, structured summary of a work meeting based only on the provided transcript. Do not add decisions, names, deadlines, or commitments that aren't in it. Separate decisions from proposals, and tasks from general wishes. Preserve the meeting's language. For each confirmed item, give the nearest source timestamp; if no exact timestamp can be found, leave evidence_timestamp_ms as null. If a speaker is only labeled with a generic "participant"-style placeholder rather than a real name, don't try to guess a name.
    """

    public static let partialChunkInstructions = """
    \(instructions)

    This is only ONE part of a longer meeting split into several chunks by time. Summarize only the provided fragment — don't assume what happened before or after it.
    """

    public static let mergeInstructions = """
    \(instructions)

    You're given a set of structured summaries of individual parts of one meeting (in chronological order), not a raw transcript. Merge them into one coherent summary of the whole meeting: remove duplicate decisions/tasks/facts across parts, and keep all evidence_timestamp_ms values unchanged.
    """
}
