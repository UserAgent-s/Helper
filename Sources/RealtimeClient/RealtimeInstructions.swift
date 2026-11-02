import Domain

public enum RealtimeInstructions {
    public static let version = AnswerInstructionsBuilder.version

    public static func system(for length: AnswerLength, background: String = "") -> String {
        system(for: length, domains: [], candidate: .migratedFromLegacyBackground(background))
    }

    public static func system(for length: AnswerLength, domains: [ExpertDomain], candidate: CandidateProfile) -> String {
        AnswerInstructionsBuilder.build(adaptation: .realtimeAudio, length: length, domains: domains, candidate: candidate)
    }

    public static let forceAnswerNow = """
    \(AnswerInstructionsBuilder.forceAnswerMarker). The user is confirming a question has already been asked. Use all context accumulated since the previous shown answer and answer now. Do not return \(AnswerInstructionsBuilder.waitForQuestionSentinel). Follow the system rules for language, senior-level quality, accuracy, and brevity.
    """

    public static let waitForQuestionSentinel = AnswerInstructionsBuilder.waitForQuestionSentinel
}
