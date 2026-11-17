import Foundation
import CVibechar

struct RecipeInfo: Decodable {
    let rule: String?; let summary: String?; let explanation: String?; let error: String
    static func validate(_ rule: String) throws -> RecipeInfo {
        guard rule.utf8.count <= 16*1024 else { throw RewriteFailure(message: "The recipe exceeds 16 KiB.") }
        let input = Array(rule.utf8)
        let data = input.withUnsafeBufferPointer { input -> Data in
            let count = vc_recipe_info(input.baseAddress,input.count,nil,0)
            var bytes = [UInt8](repeating: 0,count: count)
            precondition(bytes.withUnsafeMutableBufferPointer { vc_recipe_info(input.baseAddress,input.count,$0.baseAddress,$0.count) } == count)
            return Data(bytes)
        }
        let info = try JSONDecoder().decode(Self.self,from: data)
        guard info.error.isEmpty, info.rule != nil else { throw RewriteFailure(message: info.error) }
        return info
    }
}

struct SavedRecipe: Identifiable {
    let id: UUID
    var name: String
    let rule: String
    let info: RecipeInfo
}

/// This file contains names and validated rules only, never captured rows or examples.
@MainActor
final class RecipeStore {
    private struct Entry: Codable { let id: UUID; let name: String; let rule: String }
    private struct Library: Codable { let version: Int; let recipes: [Entry] }
    private let directory: URL?
    init(directory: URL? = nil) { self.directory = directory }
    private func file() throws -> URL {
        let folder = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,in: .userDomainMask,appropriateFor: nil,create: false)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.vibechar.app",isDirectory: true)
        return folder.appendingPathComponent("recipes.json")
    }
    func load() throws -> [SavedRecipe] {
        let url = try file(), manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return [] }
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 2*1024*1024 else {
            throw RewriteFailure(message: "The recipe library is unreadable or too large. It was left untouched.")
        }
        do {
            let library = try JSONDecoder().decode(Library.self,from: Data(contentsOf: url))
            guard library.version == 1 else { throw RewriteFailure(message: "This recipe library needs a newer Vibechar. It was left untouched.") }
            guard library.recipes.count <= 100, Set(library.recipes.map(\.id)).count == library.recipes.count else { throw CocoaError(.fileReadCorruptFile) }
            var names = Set<String>()
            var recipes: [SavedRecipe] = []
            for recipe in library.recipes {
                guard try validName(recipe.name) == recipe.name, names.insert(recipe.name.lowercased()).inserted else { throw CocoaError(.fileReadCorruptFile) }
                let info = try RecipeInfo.validate(recipe.rule)
                recipes.append(SavedRecipe(id: recipe.id,name: recipe.name,rule: info.rule!,info: info))
            }
            return recipes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch let error as RewriteFailure { throw error }
        catch { throw RewriteFailure(message: "The recipe library could not be read. It was left untouched.") }
    }
    @discardableResult
    func save(name: String, rule: String) throws -> SavedRecipe {
        let name = try validName(name), info = try RecipeInfo.validate(rule)
        var recipes = try load()
        guard recipes.count < 100 else { throw RewriteFailure(message: "Your library has 100 recipes. Remove one before saving another.") }
        try unique(name,in: recipes)
        let recipe = SavedRecipe(id: UUID(),name: name,rule: info.rule!,info: info)
        recipes.append(recipe); try write(recipes); return recipe
    }
    func rename(_ id: UUID, to name: String) throws {
        let name = try validName(name)
        var recipes = try load()
        guard let index = recipes.firstIndex(where: { $0.id == id }) else { throw RewriteFailure(message: "This recipe no longer exists. Reopen Saved Recipes.") }
        try unique(name,in: recipes.filter { $0.id != id }); recipes[index].name = name; try write(recipes)
    }
    func delete(_ id: UUID) throws { var recipes = try load(); recipes.removeAll { $0.id == id }; try write(recipes) }
    private func validName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RewriteFailure(message: "Use a name of 1–80 characters on one line.")
        }
        return name
    }
    private func unique(_ name: String, in recipes: [SavedRecipe]) throws {
        guard !recipes.contains(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw RewriteFailure(message: "A recipe with that name already exists. Choose another name.")
        }
    }
    private func write(_ recipes: [SavedRecipe]) throws {
        let url = try file(), manager = FileManager.default, folder = url.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: folder,withIntermediateDirectories: true,attributes: [.posixPermissions: 0o700])
            let entries = recipes.map { Entry(id: $0.id,name: $0.name,rule: $0.rule) }
            let data = try JSONEncoder().encode(Library(version: 1,recipes: entries))
            guard data.count <= 2*1024*1024 else { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url,options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600],ofItemAtPath: url.path)
        } catch { throw RewriteFailure(message: "Couldn't save the recipe library. Check available space and folder permissions.") }
    }
}
