import Foundation
@testable import Sonar

/// A minimal, deterministic `Track` fixture for the pure-logic tests. Only
/// `id` matters for equality/identity in the code under test, so the rest of
/// the fields are filled with cheap placeholders.
func track(_ name: String) -> Track {
    Track(id: URL(string: "file:///\(name).mp3")!,
          title: name,
          artist: "",
          album: "",
          duration: 100)
}
