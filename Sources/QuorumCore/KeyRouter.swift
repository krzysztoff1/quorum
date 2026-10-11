import Foundation

public enum Key: Equatable, Sendable {
    case character(Character)
    case returnKey
    case escape
    case tab
    case up
    case down
}

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1)
    public static let option = KeyModifiers(rawValue: 2)
    public static let shift = KeyModifiers(rawValue: 4)
    public static let control = KeyModifiers(rawValue: 8)
}

public struct KeyPress: Equatable, Sendable {
    public let key: Key
    public let modifiers: KeyModifiers

    public init(_ key: Key, _ modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

public enum KeyScope: Equatable, Sendable {
    case list
    case composer
    case question(railOpen: Bool)
    case scoping(ScopingFlow.Step)
    case palette
}

public extension KeyScope {
    static func resolve(paletteOpen: Bool, onNewQuestion: Bool, step: ScopingFlow.Step, railOpen: Bool) -> KeyScope {
        if paletteOpen { return .palette }
        if onNewQuestion { return step == .drafting ? .composer : .scoping(step) }
        return .question(railOpen: railOpen)
    }
}

public struct KeyContext: Equatable, Sendable {
    public let scope: KeyScope
    public let typing: Bool

    public init(scope: KeyScope, typing: Bool) {
        self.scope = scope
        self.typing = typing
    }
}

public enum AppCommand: Equatable, Sendable {
    case palette
    case newQuestion
    case jumpToQuestion(Int)
    case previousQuestion
    case nextQuestion
    case toggleSidebar
    case nextClaim
    case previousClaim
    case openSource
    case nextSource
    case previousSource
    case closeRail
    case openOriginal
    case researchConflict
    case toggleEarlier
    case toggleWork
    case followUp
    case copyMarkdown
    case stop
    case toggleTier
    case ask
    case pickOption(question: Int, option: Int)
    case continueScoping
    case backToWords
    case startRun
    case editResolved
}

public enum KeyRouter {
    public static func command(for press: KeyPress, in context: KeyContext) -> AppCommand? {
        let modifiers = press.modifiers
        if modifiers.contains(.command) { return commandChord(press, context) }
        if context.scope == .palette { return nil }
        if modifiers.contains(.option) { return optionChord(press, context) }
        if press.key == .tab { return tabCommand(context.scope) }
        if context.scope == .composer { return composerKey(press) }
        if context.typing || modifiers.contains(.control) { return nil }
        return plainKey(press, context.scope)
    }

    private static func commandChord(_ press: KeyPress, _ context: KeyContext) -> AppCommand? {
        let modifiers = press.modifiers
        guard case .character(let character) = press.key else {
            return press.key == .returnKey ? commandReturn(context.scope) : nil
        }
        if character == "k", modifiers == .command { return .palette }
        if context.scope == .palette || modifiers != .command && !(character == "c" && modifiers == [.command, .shift]) { return nil }
        switch character {
        case "n": return .newQuestion
        case "\\": return .toggleSidebar
        case "1"..."9": return .jumpToQuestion(Int(String(character)) ?? 0)
        case "l": return isQuestion(context.scope) ? .followUp : nil
        case ".": return isQuestion(context.scope) ? .stop : nil
        case "c": return isQuestion(context.scope) && modifiers.contains(.shift) ? .copyMarkdown : nil
        default: return nil
        }
    }

    private static func commandReturn(_ scope: KeyScope) -> AppCommand? {
        switch scope {
        case .question(railOpen: true): return .openOriginal
        case .scoping(.confirming): return .startRun
        case .composer: return .ask
        default: return nil
        }
    }

    private static func optionChord(_ press: KeyPress, _ context: KeyContext) -> AppCommand? {
        guard !context.typing, press.modifiers == .option else { return nil }
        switch press.key {
        case .up: return .previousQuestion
        case .down: return .nextQuestion
        default: return nil
        }
    }

    private static func tabCommand(_ scope: KeyScope) -> AppCommand? {
        switch scope {
        case .composer, .scoping(.confirming): return .toggleTier
        default: return nil
        }
    }

    private static func composerKey(_ press: KeyPress) -> AppCommand? {
        press.key == .returnKey && !press.modifiers.contains(.shift) ? .ask : nil
    }

    private static func plainKey(_ press: KeyPress, _ scope: KeyScope) -> AppCommand? {
        if case .character(let character) = press.key, Character(character.lowercased()) == "n" { return .newQuestion }
        switch scope {
        case .question(let railOpen): return questionKey(press, railOpen: railOpen)
        case .scoping(let step): return scopingKey(press, step: step)
        default: return nil
        }
    }

    private static func questionKey(_ press: KeyPress, railOpen: Bool) -> AppCommand? {
        switch press.key {
        case .returnKey: return .openSource
        case .escape: return railOpen ? .closeRail : nil
        case .character(let character):
            switch Character(character.lowercased()) {
            case "j": return .nextClaim
            case "k": return .previousClaim
            case "]": return .nextSource
            case "[": return .previousSource
            case "g": return .toggleWork
            case "r": return .researchConflict
            case "e": return .toggleEarlier
            default: return nil
            }
        default: return nil
        }
    }

    private static func scopingKey(_ press: KeyPress, step: ScopingFlow.Step) -> AppCommand? {
        switch step {
        case .drafting: return nil
        case .scoping: return press.key == .escape ? .backToWords : nil
        case .clarifying:
            if press.key == .returnKey { return .continueScoping }
            if press.key == .escape { return .backToWords }
            if case .character(let character) = press.key, let target = ScopeKeys.target(for: character, questions: 3) {
                return .pickOption(question: target.question, option: target.option)
            }
            return nil
        case .confirming:
            if press.key == .returnKey { return .startRun }
            if press.key == .escape { return .backToWords }
            if case .character(let character) = press.key, Character(character.lowercased()) == "e" { return .editResolved }
            return nil
        }
    }

    private static func isQuestion(_ scope: KeyScope) -> Bool {
        if case .question = scope { return true }
        return false
    }
}
