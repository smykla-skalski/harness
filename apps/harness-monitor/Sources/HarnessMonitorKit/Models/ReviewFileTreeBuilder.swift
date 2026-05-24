enum ReviewFileTreeBuilder {
  static func build(files: [ReviewFile]) -> [ReviewFileTreeNode] {
    let root = MutableReviewFileTreeNode(name: "", fullPath: "")
    for file in files {
      insert(path: file.path, into: root)
    }
    return root.children.map(\.snapshot)
  }

  private static func insert(path: String, into root: MutableReviewFileTreeNode) {
    let segments = path.split(separator: "/").map(String.init)
    guard !segments.isEmpty else { return }
    var current = root
    var prefix = ""
    for index in segments.indices {
      let segment = segments[index]
      let fullPath = prefix.isEmpty ? segment : "\(prefix)/\(segment)"
      if index == segments.index(before: segments.endIndex) {
        current.children.append(
          MutableReviewFileTreeNode(name: segment, fullPath: fullPath)
        )
      } else {
        current = current.directory(named: segment, fullPath: fullPath)
      }
      prefix = fullPath
    }
  }
}

private final class MutableReviewFileTreeNode {
  let name: String
  let fullPath: String
  var children: [MutableReviewFileTreeNode] = []
  private var directoryIndexByName: [String: Int] = [:]

  init(name: String, fullPath: String) {
    self.name = name
    self.fullPath = fullPath
  }

  var snapshot: ReviewFileTreeNode {
    ReviewFileTreeNode(
      name: name,
      fullPath: fullPath,
      children: children.map(\.snapshot)
    )
  }

  func directory(named name: String, fullPath: String) -> MutableReviewFileTreeNode {
    if let index = directoryIndexByName[name] {
      return children[index]
    }
    let child = MutableReviewFileTreeNode(name: name, fullPath: fullPath)
    directoryIndexByName[name] = children.count
    children.append(child)
    return child
  }
}
