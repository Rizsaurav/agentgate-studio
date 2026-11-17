import unittest

from admin import is_admin
from profile import display_name
from users import get_user


class UserTests(unittest.TestCase):
    def test_lookup(self):
        self.assertEqual(get_user(1), 'ada')

    def test_display(self):
        self.assertEqual(display_name(2), 'Linus')

    def test_admin(self):
        self.assertTrue(is_admin(1))


if __name__ == '__main__':
    unittest.main()
