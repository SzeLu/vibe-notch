//
//  GitInfo.swift
//  VibeNotch
//
//  Lightweight git repository info for a working directory.
//
//  Reads `.git/HEAD` directly instead of spawning `git`, so it's cheap enough
//  to call from row views. Handles worktrees/submodules where `.git` is a file
//  pointing at the real git directory.
//

import Foundation

enum GitInfo {
    /// Resolved repository info for a working directory.
    struct Repo: Equatable, Sendable {
        /// Absolute path of the repository root.
        let root: String
        /// Current branch name (`nil` when HEAD is detached).
        let branch: String?
        /// Short commit hash, present when HEAD is detached.
        let shortHash: String?

        /// Label to show for the branch (branch name, or short hash when detached).
        var displayBranch: String {
            if let branch, !branch.isEmpty { return branch }
            if let shortHash, !shortHash.isEmpty { return shortHash }
            return ""
        }
    }

    /// Returns repo info for `cwd`, or `nil` when it isn't inside a git repo.
    static func repo(for cwd: String) -> Repo? {
        guard !cwd.isEmpty else { return nil }
        guard let root = findRepoRoot(from: cwd) else { return nil }
        guard let gitDir = resolveGitDir(root: root) else { return nil }

        let headURL = URL(fileURLWithPath: gitDir).appendingPathComponent("HEAD")
        guard let head = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("ref:") {
            let ref = String(trimmed.dropFirst("ref:".count))
                .trimmingCharacters(in: .whitespaces)
            let branch = ref.hasPrefix("refs/heads/")
                ? String(ref.dropFirst("refs/heads/".count))
                : ref
            return Repo(root: root, branch: branch, shortHash: nil)
        }

        // Detached HEAD: HEAD contains a raw commit hash.
        let hash = String(trimmed.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hash.isEmpty else { return nil }
        return Repo(root: root, branch: nil, shortHash: String(hash.prefix(7)))
    }

    // MARK: - Resolution

    /// Walks up from `path` looking for a `.git` entry.
    private static func findRepoRoot(from path: String) -> String? {
        var url = URL(fileURLWithPath: path).resolvingSymlinksInPath()

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
            url = url.deletingLastPathComponent()
        }

        while true {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    /// Resolves the actual git directory, handling worktrees/submodules where
    /// `.git` is a file containing `gitdir: <path>`.
    private static func resolveGitDir(root: String) -> String? {
        let dotGit = (root as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) else { return nil }

        if isDir.boolValue { return dotGit }

        guard let content = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let firstLine = content.split(separator: "\n").first,
              firstLine.hasPrefix("gitdir:") else { return nil }

        let raw = String(firstLine.dropFirst("gitdir:".count))
            .trimmingCharacters(in: .whitespaces)
        let resolved = URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: root))
            .standardizedFileURL
        return resolved.path
    }
}
