import Foundation

enum SampleData {
    static let json = """
    {
      "store": {
        "name": "Jayson Books",
        "open": true,
        "rating": 4.6,
        "book": [
          {
            "category": "reference",
            "author": "Nigel Rees",
            "title": "Sayings of the Century",
            "price": 8.95,
            "published": "1996-04-12",
            "tags": ["classic", "quotes"]
          },
          {
            "category": "fiction",
            "author": "Evelyn Waugh",
            "title": "Sword of Honour",
            "price": 12.99,
            "published": "1952-10-01",
            "tags": ["war", "trilogy"]
          },
          {
            "category": "fiction",
            "author": "Herman Melville",
            "title": "Moby Dick",
            "isbn": "0-553-21311-3",
            "price": 8.99,
            "published": "1851-10-18",
            "tags": []
          },
          {
            "category": "fiction",
            "author": "J. R. R. Tolkien",
            "title": "The Lord of the Rings",
            "isbn": "0-395-19395-8",
            "price": 22.99,
            "published": "1954-07-29",
            "tags": ["fantasy", "epic"]
          }
        ],
        "bicycle": {
          "color": "red",
          "price": 19.95,
          "discontinued": null
        }
      },
      "contact": {
        "email": "hello@example.com",
        "website": "https://example.com",
        "id": "5c3e0e0a-9d4b-4d6e-9a1e-2f4a7d8b9c10"
      }
    }
    """

    static let schemaTemplate = """
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "title": "Untitled",
      "type": "object",
      "properties": {
      },
      "required": []
    }
    """
}
