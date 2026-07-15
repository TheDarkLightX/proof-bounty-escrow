import unittest

from scripts.generate_deployment_manifest import parse_int


class ParseIntTest(unittest.TestCase):
    def test_accepts_json_and_cast_integer_forms(self) -> None:
        self.assertEqual(parse_int(10_000, "value"), 10_000)
        self.assertEqual(parse_int("10000", "value"), 10_000)
        self.assertEqual(parse_int("10000 [1e4]", "value"), 10_000)
        self.assertEqual(parse_int("0x2710", "value"), 10_000)
        self.assertEqual(parse_int('"0x2710"', "value"), 10_000)

    def test_rejects_negative_annotated_and_trailing_data(self) -> None:
        for value in ("-1", "10000 [1e4] trailing", "10000\nother", "", None, 1.5):
            with self.subTest(value=value), self.assertRaises(ValueError):
                parse_int(value, "value")


if __name__ == "__main__":
    unittest.main()
