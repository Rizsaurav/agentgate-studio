from users import get_user


def display_name(user_id):
    name = get_user(user_id)
    return name.title() if name else 'unknown'
