# Fork & Deploy Guide for Flexible-Power-Systems

## Step 1: Fork CitrineOS to Your Organization (2 minutes)

### Via GitHub Web Interface:
1. Go to: https://github.com/citrineos/citrineos-core
2. Click **"Fork"** button (top right)
3. Select organization: **Flexible-Power-Systems**
4. Keep repository name: **citrineos-core**
5. ✅ Check "Copy the main branch only"
6. Click **"Create fork"**

**Result:** https://github.com/Flexible-Power-Systems/citrineos-core

---

## Step 2: Clone YOUR Fork (3 minutes)

```bash
# Navigate to your organization's projects folder
cd ~/github/Flexible-Power-Systems

# Clone YOUR fork (not upstream)
git clone git@github.com:Flexible-Power-Systems/citrineos-core.git

# Enter the repo
cd citrineos-core

# Add upstream remote (for future updates)
git remote add upstream https://github.com/citrineos/citrineos-core.git

# Verify remotes
git remote -v
# origin    git@github.com:Flexible-Power-Systems/citrineos-core.git (fetch)
# origin    git@github.com:Flexible-Power-Systems/citrineos-core.git (push)
# upstream  https://github.com/citrineos/citrineos-core.git (fetch)
# upstream  https://github.com/citrineos/citrineos-core.git (push)
```

---

## Step 3: Create Your Branch (1 minute)

```bash
cd ~/github/Flexible-Power-Systems/citrineos-core

# Create and switch to feature branch
git checkout -b feature/azure-deployment

# Verify you're on the right branch
git branch
# * feature/azure-deployment
#   main
```

---

## Step 4: Migrate Your Work (3 minutes)

```bash
# Copy your modified Dockerfile
cp ./local.Dockerfile \
   ~/github/Flexible-Power-Systems/citrineos-core/Server/

# Copy your Azure infrastructure
cp -r ./azure-infra \
      ~/github/Flexible-Power-Systems/citrineos-core/Server/

# Copy deployment script
cp ./deploy-to-azure.sh \
   ~/github/Flexible-Power-Systems/citrineos-core/Server/

# Copy documentation you created
cp ./SETUP_SUMMARY.md \
   ~/github/Flexible-Power-Systems/citrineos-core/Server/

cp ./AZURE_DEPLOYMENT_GUIDE.md \
   ~/github/Flexible-Power-Systems/citrineos-core/Server/

cp ./QUICK_REFERENCE.md \
   ~/github/Flexible-Power-Systems/citrineos-core/Server/

# If you modified package.json for EVerest
cp ./package.json \
   ~/github/Flexible-Power-Systems/citrineos-core/Server/
```

---

## Step 5: Review Changes (2 minutes)

```bash
cd ~/github/Flexible-Power-Systems/citrineos-core/Server

# See what's changed
git status

# Review the changes
git diff local.Dockerfile

# Check what files are new
ls -la azure-infra/
```

---

## Step 6: Commit Your Work (3 minutes)

```bash
cd ~/github/Flexible-Power-Systems/citrineos-core/Server

# Stage all changes
git add local.Dockerfile \
        azure-infra/ \
        deploy-to-azure.sh \
        SETUP_SUMMARY.md \
        AZURE_DEPLOYMENT_GUIDE.md \
        QUICK_REFERENCE.md

# Create .gitignore for Azure secrets
cat > azure-infra/.gitignore << 'EOF'
# Ignore deployment secrets and connection info
azure-deployment-info.txt
*.bicepparam
.env.azure
deployment-outputs.json
EOF

git add azure-infra/.gitignore

# Commit with descriptive message
git commit -m "Add Azure deployment infrastructure for Flexible-Power-Systems

Changes:
- Fix SSL certificate generation in local.Dockerfile
  * Resolves 'could not load shared library' error
  * Generates self-signed cert before server start
  
- Add Azure Infrastructure as Code
  * Bicep template for Container Instances deployment
  * PostgreSQL, Storage, Hasura, CitrineOS setup
  * Automated deployment script for rg-citrine-ev-dev
  
- Add comprehensive documentation
  * SETUP_SUMMARY.md: Local development guide
  * AZURE_DEPLOYMENT_GUIDE.md: Production IaC patterns
  * QUICK_REFERENCE.md: Common commands
  * azure-infra/README.md: Deployment instructions

Tested with:
- OCPP 1.6 charger (AE5044L1GR1C00007W) ✅
- Local Docker Compose + ngrok setup ✅
- Ready for deployment to rg-citrine-ev-dev"

# Push to YOUR organization's fork
git push origin feature/azure-deployment
```

---

## Step 7: Open VS Code in Fork (1 minute)

```bash
# Open VS Code in YOUR fork
code ~/github/Flexible-Power-Systems/citrineos-core
```

**In VS Code:**
1. You'll see your fork in the workspace
2. All your changes are committed
3. You're on branch `feature/azure-deployment`
4. Ready to deploy!

---

## Step 8: Deploy to Azure (15 minutes)

```bash
# Navigate to Server directory in YOUR fork
cd ~/github/Flexible-Power-Systems/citrineos-core/Server

# Make script executable
chmod +x deploy-to-azure.sh

# Deploy to your resource group
./deploy-to-azure.sh rg-citrine-ev-dev
```

The deployment will:
1. Build image from **YOUR fork** (not upstream)
2. Push to **YOUR ACR** in rg-citrine-ev-dev
3. Deploy to **YOUR resource group**
4. Create connection info file

---

## Step 9: Create Pull Request (Optional, 2 minutes)

```bash
# Push your branch
git push origin feature/azure-deployment
```

Then on GitHub:
1. Go to: https://github.com/Flexible-Power-Systems/citrineos-core
2. Click **"Compare & pull request"**
3. Base repository: `Flexible-Power-Systems/citrineos-core` (base: main)
4. Head repository: `Flexible-Power-Systems/citrineos-core` (compare: feature/azure-deployment)
5. Title: "Add Azure deployment infrastructure"
6. Create pull request for team review

---

## What You Get

✅ **Your organization owns the fork**  
✅ **Your changes are version controlled**  
✅ **Container images come from your fork**  
✅ **Easy to sync with upstream later**  
✅ **Team can collaborate via PRs**  
✅ **Ready for CI/CD pipelines**  

---

## Future: Syncing with Upstream

When CitrineOS releases updates:

```bash
cd ~/github/Flexible-Power-Systems/citrineos-core

# Fetch upstream changes
git fetch upstream

# Switch to main
git checkout main

# Merge upstream updates
git merge upstream/main

# Push to your fork
git push origin main

# Update your feature branch
git checkout feature/azure-deployment
git rebase main
```

---

## Quick Commands Summary

```bash
# Fork Setup (one-time)
cd ~/github/Flexible-Power-Systems
git clone git@github.com:Flexible-Power-Systems/citrineos-core.git
cd citrineos-core
git remote add upstream https://github.com/citrineos/citrineos-core.git

# Deploy
cd ~/github/Flexible-Power-Systems/citrineos-core/Server
./deploy-to-azure.sh rg-citrine-ev-dev

# View logs after deployment
az container logs \
  --resource-group rg-citrine-ev-dev \
  --name aci-dev-citrineos \
  --follow
```

---

## ✅ Ready to Start?

Run this now:
```bash
# Navigate and prepare
cd ~/github/Flexible-Power-Systems
```

Then follow Step 2 onwards!
