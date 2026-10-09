import XCTest
@testable import QuorumCore

final class RestatedOpenQuestionsTests: XCTestCase {

    private let conflicts = [Conflict(
        claim: "Skala biznesowej korzyści z personalizacji w food/grocery tech",
        positions: ["Angle 2 (McKinsey benchmark): 1-2% sales lift w grocery, 5-15% ogólnie w retail",
                    "Angle 2 (vendor case studies): Starbucks $2.1B incremental revenue, Domino's 63% revenue growth — ale niezweryfikowane"])]

    private let gaps = [
        "Czy architektury embeddingowo-LLM-owe (Angle 1) mogą technicznie spełnić żądania usunięcia danych/algorithmic disgorgement wymuszane przez FTC (Angle 3) bez pełnego retrainingu modelu",
        "Czy konkretne platformy (DoorDash, Instacart, Uber Eats) formalnie klasyfikują dane o alergiach/diecie jako dane wrażliwe w swoich politykach prywatności",
        "Czy Unified Consumer Memory Platform DoorDasha (przechowujące językowe profile) samo w sobie kwalifikuje się jako przetwarzanie danych specjalnej kategorii pod GDPR",
    ]

    private let restatement = """
        ## Konflikty i luki

        - **Skala korzyści biznesowej jest sporna**: McKinsey (1-2% w grocery) vs. głośne case-study (Starbucks $2,1 mld, Domino's 63% wzrostu) — te drugie niepotwierdzone w dokumentach finansowych[^a2c2].
        - Żadna z trzech notatek nie łączy bezpośrednio architektury ML (Angle 1) z konkretnym ryzykiem regulacyjnym (Angle 3) — np. czy Unified Consumer Memory Platform DoorDasha (przechowujący językowe profile preferencji) sam w sobie kwalifikuje się jako przetwarzanie danych specjalnej kategorii pod GDPR.
        - Brak danych o tym, jak systemy embeddingowe/LLM radzą sobie technicznie z wymaganym "prawem do zapomnienia"/algorithmic disgorgement (por. sprawa WW/Kurbo) — czy da się usunąć wpływ użytkownika z wytrenowanego two-tower modelu bez pełnego retrainingu.
        - Brak weryfikacji, czy DoorDash/Instacart/Uber Eats formalnie klasyfikują dane o alergiach/diecie jako dane wrażliwe w swoich politykach prywatności (Angle 3 pokazuje tylko ogólny stan branży, nie tych konkretnych firm).
        """

    private let answer = """
        Food-tech personalizacja skonwergowała do hybrydowej architektury.

        ## Prawo i prywatność

        Dane dietetyczne są prawnie niejednoznaczne[^a3c1].
        """

    func testTheModelsOwnConflictsAndGapsSectionGivesWayToTheStructuredOne() {
        let stripped = RestatedOpenQuestions.stripped(answer + "\n\n" + restatement, conflicts: conflicts, gaps: gaps)
        XCTAssertEqual(stripped, answer)
    }

    func testASectionWithAnythingTheStructuredDataDoesNotSayIsKept() {
        let extra = restatement + "\n- Warto też sprawdzić koszty wdrożenia w małych restauracjach w Polsce."
        let text = answer + "\n\n" + extra
        XCTAssertEqual(RestatedOpenQuestions.stripped(text, conflicts: conflicts, gaps: gaps), text)
    }

    func testProseSectionsAreNeverTouched() {
        XCTAssertEqual(RestatedOpenQuestions.stripped(answer, conflicts: conflicts, gaps: gaps), answer)
    }

    func testWithNoStructuredOpenQuestionsNothingIsStripped() {
        let text = answer + "\n\n" + restatement
        XCTAssertEqual(RestatedOpenQuestions.stripped(text, conflicts: [], gaps: []), text)
    }

    func testTheNoteSaysEachGapAndConflictOnce() {
        let summary = TopicFindings(id: "s", status: .complete, preset: .standard, headline: "Odpowiedź",
                                    findings: [], conflicts: conflicts, gaps: gaps, sourcesConsulted: 0,
                                    costUSD: 0, duration: .seconds(1),
                                    writeupMarkdown: answer + "\n\n" + restatement, transcript: "", note: nil)
        let section = DiskFindingsStore.renderSection(summary, date: fixedStart, relatedLinks: [], sources: 0)
        XCTAssertFalse(section.contains("Konflikty i luki"), section)
        XCTAssertEqual(section.components(separatedBy: "formalnie klasyfikują").count - 1, 1, section)
        XCTAssertEqual(section.components(separatedBy: "Skala").count - 1, 1, section)
        XCTAssertTrue(section.contains("### Gaps & open questions"))
    }
}
