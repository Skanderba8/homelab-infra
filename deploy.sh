name: Deploy

on:
  push:
    branches: [main]

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    outputs:
      image: ${{ steps.build.outputs.image }}

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: eu-west-3

      - name: Login to ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and push image
        id: build
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker build -t $ECR_REGISTRY/homelab:$IMAGE_TAG -t $ECR_REGISTRY/homelab:latest .
          docker push $ECR_REGISTRY/homelab:$IMAGE_TAG
          docker push $ECR_REGISTRY/homelab:latest
          echo "image=$ECR_REGISTRY/homelab:$IMAGE_TAG" >> $GITHUB_OUTPUT

  deploy:
    runs-on: ubuntu-latest
    needs: build-and-push

    steps:
      - name: SSH and deploy
        uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.SSH_HOST }}
          username: ${{ secrets.SSH_USER }}
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          script: |
            cd ~/homelab
            git pull origin main
            docker compose pull
            docker compose up -d