from users import get_user


def is_admin(user_id):
    return get_user(user_id) == 'ada'
