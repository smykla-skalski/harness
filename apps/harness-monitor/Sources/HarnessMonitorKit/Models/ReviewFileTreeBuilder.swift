enum ReviewFileTreeBuilder {
  static func build(files: [ReviewFile]) -> [ReviewFileTreeNode] {
    let root = MutableReviewFileTreeNode(name: "", fullPath: "")
    for file in files {
      insert(path: file.path, into: root)
    }
    return root.children.map(\.snapshot)
  }

  private static func insert(path: String, into root: MutableReviewFileTreeNode) {
    var current = root
    var prefix = ""
    var segmentStart = skipSlashes(in: path, from: path.startIndex)
    while segmentStart < path.endIndex {
      var segmentEnd = segmentStart
      while segmentEnd < path.endIndex, path[segmentEnd] != "/" {
        segmentEnd = path.index(after: segmentEnd)
      }
      let nextSegmentStart = skipSlashes(in: path, from: segmentEnd)
      let isLeaf = nextSegmentStart == path.endIndex
      let segment = String(path[segmentStart..<segmentEnd])
      let fullPath = prefix.isEmpty ? segment : "\(prefix)/\(segment)"
      if isLeaf {
        current.children.append(
          MutableReviewFileTreeNode(name: segment, fullPath: fullPath)
        )
        return
      } else {
        current = current.directory(named: segment, fullPath: fullPath)
      }
      prefix = fullPath
      segmentStart = nextSegmentStart
    }
  }

  private static func skipSlashes(
    in path: String,
    from index: String.Index
  ) -> String.Index {
    var current = index
    while current < path.endIndex, path[current] == "/" {
      current = path.index(after: current)
    }
    return current
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
