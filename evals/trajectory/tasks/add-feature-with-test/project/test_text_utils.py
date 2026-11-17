import unittest

from text_utils import shout


class TextTests(unittest.TestCase):
    def test_shout(self):
        self.assertEqual(shout('hi'), 'HI')


if __name__ == '__main__':
    unittest.main()
