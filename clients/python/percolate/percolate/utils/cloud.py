import subprocess
import os
from percolate.utils import logger
from percolate.utils.env import PERCOLATE_ACCOUNT_SETTINGS,P8_CONTAINER_REGISTRY
import percolate as p8

def notify_api_image_updated(project_name, password):
    """
    The percolate API will allow users to send notification events to run cloud/k8 tasks
    """
    pass

def docker_login_and_push_from_project(docker_image_path="."):
    """uses the harbor user details from the project settings"""
    
    return docker_login_and_push(PERCOLATE_ACCOUNT_SETTINGS['NAME'],
                                 #we may have a customer user name but just use the project name
                                 username=PERCOLATE_ACCOUNT_SETTINGS.get('USERNAME', PERCOLATE_ACCOUNT_SETTINGS['NAME']),
                                 #we may have a custom password but just use the DB password 
                                 password=PERCOLATE_ACCOUNT_SETTINGS.get('PASSWORD', PERCOLATE_ACCOUNT_SETTINGS['P8_PG_PASSWORD']),
                                 docker_image_path=docker_image_path )
        
        
def ensure_buildx_builder(docker_config_dir: str, name: str = "p8builder"):
    """build x context needed """
    inspect_cmd = ["docker", "--config", docker_config_dir, "buildx", "inspect", name]
    create_cmd = ["docker", "--config", docker_config_dir, "buildx", "create", "--name", name, "--use"]
    use_cmd = ["docker", "--config", docker_config_dir, "buildx", "use", name]
    bootstrap_cmd = ["docker", "--config", docker_config_dir, "buildx", "inspect", name, "--bootstrap"]

    try:
        subprocess.run(inspect_cmd, check=True, capture_output=True)
        subprocess.run(use_cmd, check=True)
    except subprocess.CalledProcessError:
        subprocess.run(create_cmd, check=True)
    subprocess.run(bootstrap_cmd, check=True)

     
def docker_login_and_push(project_name, username, password, image_name="customer-api", image_tag="latest", docker_image_path="."):
    """
    a users custom API can be updated by building a docker image
    This uses buildkit so user should check
    ```
    docker buildx create --use
    ```
    """
    docker_config_dir = "/tmp/docker-config"
    os.environ["DOCKER_BUILDKIT"] = "1"
    
    """1 create a login context"""
    try:
        login_command = [
            "docker",
            "--config", docker_config_dir,
            "login", P8_CONTAINER_REGISTRY,
            "-u", username,
            "-p", f'{password}'
        ]
        logger.info("Logging in to Docker registry...")
        subprocess.check_call(login_command)
        logger.info("Login successful!")
    except subprocess.CalledProcessError as e:
        logger.warning(f"Login failed: {e}")
        return


    print("------")
    #ensure_buildx_builder(docker_config_dir)
    print("------")

    """2. Use builkit in that context to tag and push the image"""
    try:
        build_command = [
            "docker",   "--config", docker_config_dir,
            "buildx", "build", "--push",
            "-t", f"{P8_CONTAINER_REGISTRY}/{project_name}/{image_name}:{image_tag}",
            docker_image_path
        ]
        logger.info("Building and pushing the Docker image...")
        subprocess.check_call(build_command)
        logger.info(f"Image {image_name}:{image_tag} pushed successfully!")
    except subprocess.CalledProcessError as e:
        logger.warning(f"Build and push failed: {e}")
        return

    """3. Notify percolate there is a new image for this project"""
    notify_api_image_updated(project_name, password)
    